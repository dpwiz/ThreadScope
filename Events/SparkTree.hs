module Events.SparkTree (
     SparkTree(..), SparkNode(..),
     mkSparkTree,
     eventsToSparkDurations,
     sparkProfile,
     sparkTreeMaxDepth,
  ) where

import Data.Word (Word64)

import qualified GHC.RTS.Events as GHC
import GHC.RTS.Events (Timestamp)

import Text.Printf

-- We map the events onto a binary search tree, so that we can easily
-- find the events that correspond to a particular view of the
-- timeline.  Additionally, each node of the tree contains a summary
-- of the information below it, so that we can render views at various
-- levels of resolution.  For example, if a tree node would represent
-- less than one pixel on the display, there is no point is descending
-- the tree further.

-- We only split at event boundaries; we never split an event into
-- multiple pieces.  Therefore, the binary tree is only roughly split
-- by time, the actual split depends on the distribution of events
-- below it.

data SparkDuration =
  SparkDuration { startT, endT :: Timestamp,
                  startCount, endCount :: SparkCounters }
  deriving Show

data SparkCounters =
  SparkCounters { sparksCreated, sparksDud, sparksOverflowed,
                  sparksConverted, sparksFizzled, sparksGCd,
                  sparksRemaining :: {-# UNPACK #-}! Word64 }
  deriving (Show, Eq)

data SparkTree
  = SparkTree
      {-#UNPACK#-}!Timestamp  -- start time of this span
      {-#UNPACK#-}!Timestamp  -- end time of this span
      SparkNode
  deriving Show

data SparkNode
  = SparkSplit
      {-#UNPACK#-}!Timestamp  -- time used to split the span into two parts
      SparkNode  -- the LHS split; all data lies completely between
                 -- start and split
      SparkNode  -- the RHS split; all data lies completely between
                 -- split and end
      SparkCounters  -- the delta of spark stats at the end and at the start
  | SparkTreeLeaf
      SparkCounters  -- spark stats at the start
      SparkCounters  -- spark stats at the end
  | SparkTreeEmpty   -- after the last GC

  deriving Show


mkSparkTree :: [SparkDuration] -> Timestamp -> SparkTree
mkSparkTree es endTime =
  SparkTree s e $
  -- trace (show tree) $
  tree
 where
  tree = splitSparks es endTime
  (s,e) = if null es then (0, 0) else (startT (head es), endTime)


splitSparks :: [SparkDuration]  -- events
            -> Timestamp        -- end time of last event in the list
            -> SparkNode
splitSparks [] !_endTime =
  -- if len /= 0 then error "splitSparks0" else
  SparkTreeEmpty

splitSparks [e] !_endTime =
  SparkTreeLeaf (startCount e) (endCount e)

splitSparks es !endTime
  | null rhs
  = splitSparks es lhs_end

  | null lhs
  = error (printf "null lhs: len = %d, startTime = %d, endTime = %d, lhs_len = %d\n" (length es) startTime endTime ++ '\n': show es)

  | otherwise
  = -- trace (printf "len = %d, startTime = %d, endTime = %d, lhs_len = %d\n" len startTime endTime lhs_len) $
    -- if len /= length es || length lhs + length rhs /= len then error (printf "splitSparks3; %d %d %d %d %d" len (length es) (length lhs) lhs_len (length rhs))  else
    SparkSplit (startT $ head rhs)
               ltree
               rtree
               (subtractSparkCounters endCounter startCounter)
    where
    startCounter = startCount $ head es
    endCounter = endCount $ last rhs
    startTime = startT $ head es
    splitTime = startTime + (endTime - startTime) `div` 2

    (lhs, lhs_end, rhs) = splitSparkList es [] splitTime 0

    ltree = splitSparks lhs lhs_end
    rtree = splitSparks rhs endTime


splitSparkList :: [SparkDuration]
               -> [SparkDuration]
               -> Timestamp
               -> Timestamp
               -> ([SparkDuration], Timestamp, [SparkDuration])
splitSparkList [] acc !_tsplit !tmax
  = (reverse acc, tmax, [])
splitSparkList (e:es) acc !tsplit !tmax
  | t < tsplit -- pick all events that start before the split
  = splitSparkList es (e:acc) tsplit (max tmax t)
  | otherwise
  = (reverse acc, tmax, e:es)
  where
    t = startT e

addSparkCounters :: SparkCounters -> SparkCounters -> SparkCounters
addSparkCounters
  (SparkCounters sparksCreated1 sparksDud1 sparksOverflowed1
                 sparksConverted1 sparksFizzled1 sparksGCd1
                 sparksRemaining1)
  (SparkCounters sparksCreated2 sparksDud2 sparksOverflowed2
                 sparksConverted2 sparksFizzled2 sparksGCd2
                 sparksRemaining2)
  = SparkCounters
      (sparksCreated2 + sparksCreated1)
      (sparksDud2 + sparksDud1)
      (sparksOverflowed2 + sparksOverflowed1)
      (sparksConverted2 +  sparksConverted1)
      (sparksFizzled2 + sparksFizzled1)
      (sparksGCd2 + sparksGCd1)
      (sparksRemaining2 + sparksRemaining1)

-- Warning: the values in the second counter has to be greater or equal
-- to the values int he first counter.
subtractSparkCounters :: SparkCounters -> SparkCounters -> SparkCounters
subtractSparkCounters
  (SparkCounters sparksCreated1 sparksDud1 sparksOverflowed1
                 sparksConverted1 sparksFizzled1 sparksGCd1
                 sparksRemaining1)
  (SparkCounters sparksCreated2 sparksDud2 sparksOverflowed2
                 sparksConverted2 sparksFizzled2 sparksGCd2
                 sparksRemaining2)
  = SparkCounters
      (sparksCreated2 - sparksCreated1)
      (sparksDud2 - sparksDud1)
      (sparksOverflowed2 - sparksOverflowed1)
      (sparksConverted2 -  sparksConverted1)
      (sparksFizzled2 - sparksFizzled1)
      (sparksGCd2 - sparksGCd1)
      (sparksRemaining2 - sparksRemaining1)

zeroSparkCounters :: SparkCounters
zeroSparkCounters = SparkCounters 0 0 0 0 0 0 0


-- Warning: cannot be applied to a suffix of the log (assumes start at time 0).
eventsToSparkDurations :: [GHC.Event] -> [SparkDuration]
eventsToSparkDurations es =
  let aux _startTime _startCounters [] = []
      aux startTime startCounters (event : events) =
        case GHC.spec event of
          GHC.SparkCounters crt dud ovf cnv fiz gcd rem ->
            let endTime = GHC.time event
                endCounters = SparkCounters crt dud ovf cnv fiz gcd rem
                sd = SparkDuration
                       { startT = startTime,
                         endT = endTime,
                         startCount = startCounters,
                         endCount = endCounters }
            in sd : aux endTime endCounters events
          _otherEvent -> aux startTime startCounters events
  in aux 0 zeroSparkCounters es


-- For each timeslice, gives the number of spark transitions during that period.
-- Approximated from the aggregated data at the level of the spark tree
-- covering intervals of the size similar to the timeslice size.
sparkProfile :: Timestamp -> Timestamp -> Timestamp -> SparkTree ->
                [SparkCounters]
sparkProfile slice start0 end0 t
  = {- trace (show flat) $ -} chopped

  where
   -- do an extra slice at both ends
   start = if start0 < slice then start0 else start0 - slice
   end   = end0 + slice

   flat = flatten start t []
   chopped0 = chop zeroSparkCounters start flat

   chopped | start0 < slice = zeroSparkCounters : chopped0
           | otherwise      = chopped0

   flatten :: Timestamp -> SparkTree -> [SparkTree] -> [SparkTree]
   flatten _start (SparkTree _s _e SparkTreeEmpty) rest = rest
   flatten start t@(SparkTree s e (SparkSplit split l r _)) rest
     | e   <= start   = rest
     | end <= s       = rest
     | start >= split = flatten start (SparkTree split e r) rest
     | end   <= split = flatten start (SparkTree s split l) rest
     | e - s > slice  = flatten start (SparkTree s split l) $
                        flatten start (SparkTree split e r) rest
     | otherwise      = t : rest
   flatten _start t@(SparkTree _s _e (SparkTreeLeaf _ _)) rest
     = t : rest

   chop :: SparkCounters -> Timestamp -> [SparkTree] -> [SparkCounters]
   chop sofar start _ts
     | start >= end = if sofar /= zeroSparkCounters then [sofar] else []
   chop sofar start []
     = sofar : chop zeroSparkCounters (start+slice) []
   chop sofar start (t : ts)
     | e <= start
     = if sofar /= zeroSparkCounters
          then error "chop"
          else chop sofar start ts
     | s >= start + slice
     = sofar : chop zeroSparkCounters (start + slice) (t : ts)
     | e > start + slice
     = (addSparkCounters sofar created_in_this_slice) :
       chop zeroSparkCounters (start + slice) (t : ts)
     | otherwise
     = chop (addSparkCounters sofar created_in_this_slice) start ts
     where
       (s, e) | SparkTree s e _ <- t  = (s, e)

       created_in_this_slice
         | SparkTree _ _ (SparkTreeLeaf sc ec)     <- t  =
           subtractSparkCounters ec sc
         | SparkTree _ _ (SparkTreeEmpty)          <- t  =
           zeroSparkCounters
         | SparkTree _ _ (SparkSplit _ _ _ cDelta) <- t  =
           cDelta


sparkTreeMaxDepth :: SparkTree -> Int
sparkTreeMaxDepth (SparkTree _ _ t) = sparkNodeMaxDepth t

sparkNodeMaxDepth :: SparkNode -> Int
sparkNodeMaxDepth (SparkSplit _ lhs rhs _)
  = 1 + sparkNodeMaxDepth lhs `max` sparkNodeMaxDepth rhs
sparkNodeMaxDepth _ = 1