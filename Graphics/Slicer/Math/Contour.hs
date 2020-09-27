-- Slicer.
{-
 - Copyright 2016 Noah Halford and Catherine Moresco
 - Copyright 2019 Julia Longtin
 -
 - This program is free software: you can redistribute it and/or modify
 - it under the terms of the GNU Affero General Public License as published by
 - the Free Software Foundation, either version 3 of the License, or
 - (at your option) any later version.
 -
 - This program is distributed in the hope that it will be useful,
 - but WITHOUT ANY WARRANTY; without even the implied warranty of
 - MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 - GNU Affero General Public License for more details.

 - You should have received a copy of the GNU Affero General Public License
 - along with this program.  If not, see <http://www.gnu.org/licenses/>.
 -}

{- The purpose of this file is to hold information about contoured surfaces. -}

module Graphics.Slicer.Math.Contour (followingLine, preceedingLine, getContours, makeContourTree, ContourTree(ContourTree), contourContainsContour) where

import Prelude ((==), otherwise, (.), null, (<$>), ($), (>), length, Show, filter, (/=), odd, snd, error, (<>), show, fst, Bool(False), Eq, Show, not, even, compare, Ordering(EQ))

import Data.List(tail, last, head, partition, reverse, sortBy)

import Data.Maybe(Maybe(Just,Nothing), catMaybes, mapMaybe)

import Graphics.Slicer.Math.Definitions (Contour(PointSequence), Point2(Point2))

import Graphics.Slicer.Math.Line (Line(Line), lineFromEndpoints, makeLinesLooped, makeLines, endpoint, pointSlopeLength, midpoint, lineSlope, perpendicularBisector, flipLine)

import Graphics.Slicer.Math.PGA (Intersection(NoIntersection, IntersectsAt, Parallel, AntiParallel, HitStartPointL2, HitEndPointL2, Collinear, LColinear), lineIntersection, SearchDirection (Clockwise), lineBetween)

import Graphics.Implicit.Definitions (ℝ)

-- Unapologetically ripped from ImplicitCAD.
-- Added the ability to look at line segments backwards.

-- | The goal of getLoops is to extract loops from a list of segments.
--   The input is a list of segments.
--   The output a list of loops, where each loop is a list of
--   segments, which each piece representing a "side".

-- For example:
-- Given points [[1,2],[5,1],[3,4,5], ... ]
-- notice that there is a loop 1,2,3,4,5... <repeat>
-- But we give the output [ [ [1,2], [3,4,5], [5,1] ], ... ]
-- so that we have the loop, and also knowledge of how
-- the list is built (the "sides" of it).

getLoops :: (Show a, Eq a) => [[a]] -> [[[a]]]
getLoops a = getLoops' a []

-- We will be actually doing the loop extraction with
-- getLoops'

-- | getLoops' has a first argument of the segments as before,
--   but a second argument which is the loop presently being
--   constructed.

-- | so we begin with the "building loop" being empty.
getLoops' :: (Show a, Eq a) => [[a]] -> [[a]] -> [[[a]]]

-- | If there aren't any segments, and the "building loop" is empty, produce no loops.
getLoops' [] [] = []

-- | If the building loop is empty, stick the first segment we have onto it to give us something to build on.
getLoops' (x:xs) [] = getLoops' xs [x]

-- | A loop is finished if its start and end are the same.
-- Return it and start searching for another loop.
getLoops' segs workingLoop
  | head (head workingLoop) == last (last workingLoop) = workingLoop : getLoops' segs []

-- | Finally, we search for pieces that can continue the working loop,
-- | and stick one on if we find it.
-- Otherwise... something is really screwed up.
getLoops' segs workingLoop =
  let
    presEnd :: [[a]] -> a
    presEnd = last . last
    connectsBackwards [] = False
    connectsBackwards [_] = False
    connectsBackwards (_:xs) = last xs == presEnd workingLoop
    connects (x:_) = x == presEnd workingLoop
    -- Handle the empty case.
    connects [] = False
    -- divide our set into sequences that connect, and sequences that don't.
    (possibleConts, nonConts) = partition connects segs
    (possibleBackConts, nonBackConts) = partition connectsBackwards segs
    (next, unused)
      | not $ null possibleConts     = (head possibleConts, tail possibleConts <> nonConts)
      | not $ null possibleBackConts = (reverse $ head possibleBackConts, tail possibleBackConts <> nonBackConts)
      | otherwise = error $ "unclosed loop in paths given: \nWorking: " <> show workingLoop <> "\nRemainder:" <> show nonConts <> "\n"
  in
    if null next
    then workingLoop : getLoops' segs []
    else getLoops' unused (workingLoop <> [next])

-- | Turn pairs of points into lists of points in sequence.
-- FIXME: flip contours the 'right' way.
getContours :: [(Point2,Point2)] -> [Contour]
getContours pointPairs = maybeFlipContour <$> foundContours
  where
    contourAsPoints :: [(Point2,Point2)] -> [Point2]
    contourAsPoints contour = fst <$> contour
    contourAsPointPairs :: [[Point2]] -> [(Point2,Point2)]
    contourAsPointPairs contourPointPairs = (\[a,b] -> (a,b)) <$> contourPointPairs
    foundContours = PointSequence . contourAsPoints . contourAsPointPairs <$> mapMaybe contourLongEnough foundContourSets
    contourLongEnough :: [[Point2]] -> Maybe [[Point2]]
    contourLongEnough pts
      | length pts > 2 = Just pts
      -- NOTE: returning nothing here, even though this is an error condition, and a sign that the input file has two triangles that intersect. should not happen.
      | otherwise = Nothing -- error $ "fragment insufficient to be a contour found: " <> show pts <> "\n"
    foundContourSets :: [[[Point2]]]
    foundContourSets = getLoops $ (\(a,b) -> [a,b]) <$> sortPairs pointPairs
      where
        -- Sort the list to begin with, so that differently ordered input lists give the same output.
        sortPairs :: [(Point2,Point2)] -> [(Point2,Point2)]
        sortPairs pairs = sortBy (\a b -> if (compare (fst a) (fst b)) == EQ then compare (snd a) (snd b) else compare (fst a) (fst b)) pairs
    -- make sure a contour is wound the right way, so that the inside of the contour is on the right side of a line segment.
    maybeFlipContour :: Contour -> Contour
    maybeFlipContour c@(PointSequence contourPoints) = if odd (length $ intersectionsToOrigin c firstLine)
                                                       then c
                                                       else PointSequence $ reverse contourPoints
      where
        firstLine = head $ makeLines contourPoints

-- | a contour tree. A contour, which contains a list of contours that are cut out of the first contour, each of them contaiting a list of contours of positive space.. recursively.
newtype ContourTree = ContourTree (Contour, [ContourTree])
  deriving (Show)

-- | Contstruct a set of contour trees. that is to say, a set of contours, containing a set of contours that is negative space, containing a set of contours that is positive space..
makeContourTree :: [Contour] -> [ContourTree]
makeContourTree []        = []
makeContourTree [contour] = [ContourTree (contour, [])]
makeContourTree contours  = [ContourTree (foundContour, makeContourTree $ contoursWithAncestor contours foundContour) | foundContour <- contoursWithoutParents contours]
  where
    contoursWithAncestor cs c = mapMaybe (\cx -> if contourContainsContour c cx then Just cx else Nothing) $ filter (/=c) cs
    contoursWithoutParents cs = catMaybes $ [ if null $ mapMaybe (\cx -> if contourContainedByContour contourToCheck cx then Just cx else Nothing) (filter (/=contourToCheck) cs) then Just contourToCheck else Nothing | contourToCheck <- cs ]

-- | determine whether a contour is contained inside of another contour.
-- FIXME: magic numbers.
contourContainsContour :: Contour -> Contour -> Bool
contourContainsContour parent child = odd noIntersections
  where
    noIntersections = length $ getContourLineIntersections parent $ lineToEdge $ innerPointOf child
    lineToEdge p = lineFromEndpoints p (Point2 (-1,-1))
    getContourLineIntersections :: Contour -> Line -> [Point2]
    getContourLineIntersections (PointSequence contourPoints) line
      | null contourPoints = []
      | otherwise = mapMaybe (saneIntersection . lineIntersection line) $ makeLinesLooped contourPoints
    saneIntersection :: Intersection -> Maybe Point2
    saneIntersection (IntersectsAt p2) = Just p2
    saneIntersection NoIntersection = Nothing
    saneIntersection Parallel = Nothing
    saneIntersection AntiParallel = Nothing
    saneIntersection Collinear = Nothing
    saneIntersection (LColinear _ _) = Nothing
    saneIntersection res = error $ "insane result drawing a line to the edge: " <> show res <> "\n"
    innerPointOf contour = innerPerimeterPoint 0.00001 contour $ oneLineOf contour
      where
        oneLineOf (PointSequence contourPoints) = head $ makeLines contourPoints

-- | determine whether a contour is contained by another contour.
contourContainedByContour :: Contour -> Contour -> Bool
contourContainedByContour child parent = contourContainsContour parent child

-- Search the given sequential list of lines (assumedly generated from a contour), and return the line after this one.
followingLine :: [Line] -> Line -> Line
followingLine x l = followingLineLooped x x l
  where
    followingLineLooped :: [Line] -> [Line] -> Line -> Line
    followingLineLooped [] _ l1 = error $ "reached beginning of contour, and did not find supplied line: " <> show l1 <> "\n"
    followingLineLooped _ [] l1 = error $ "reached end of contour, and did not find supplied line: " <> show l1 <> "\n"
    followingLineLooped [a] (b:_) l1 = if a == l1 then b else followingLineLooped [a] [] l1
    followingLineLooped (a:b:xs) set l1 = if a == l1 then b else followingLineLooped (b:xs) set l1

-- Search the given sequential list of lines (assumedly generated from a contour), and return the line before this one.
preceedingLine :: [Line] -> Line -> Line
preceedingLine x l = preceedingLineLooped x x l
  where
    preceedingLineLooped :: [Line] -> [Line] -> Line -> Line
    preceedingLineLooped [] _ l1 = error $ "reached beginning of contour, and did not find supplied line: " <> show l1 <> "\n"
    preceedingLineLooped _ [] l1 = error $ "reached end of contour, and did not find supplied line: " <> show l1 <> "\n"
    preceedingLineLooped [a] (b:_) l1 = if b == l1 then a else preceedingLineLooped [a] [] l1
    preceedingLineLooped (a:b:xs) set l1 = if b == l1 then a else preceedingLineLooped (b:xs) set l1

-- | Find a point on the interior of the given contour, on the perpendicular bisector of the given line, a given distance from the line.
innerPerimeterPoint :: ℝ -> Contour -> Line -> Point2
innerPerimeterPoint distance contour l@(Line p _)
    | even numIntersections  = sameSide
    | otherwise              = otherSide
    where
      l0 = lineFromEndpoints (midpoint l) (Point2 (-1,-1))
      lineHalvesRaw = (lineFromEndpoints (midpoint l) p, lineFromEndpoints (midpoint l) (endpoint l))
      l'@(Line p' _) = if lineBetween (fst lineHalvesRaw) Clockwise l0 (snd lineHalvesRaw)
                       then flipLine l
                       else l
      lineHalves = (lineFromEndpoints (midpoint l') p', lineFromEndpoints (midpoint l') (endpoint l'))
      bisector@(Line _ m) = perpendicularBisector l'
      sameSide = if lineBetween (fst lineHalves) Clockwise l0 (snd lineHalves) == lineBetween (fst lineHalves) Clockwise bisector (snd lineHalves)
                 then endpoint $ pointSlopeLength (midpoint l') (lineSlope m) distance
                 else endpoint $ pointSlopeLength (midpoint l') (lineSlope m) (-distance)
      otherSide = if lineBetween (fst lineHalves) Clockwise l0 (snd lineHalves) == lineBetween (fst lineHalves) Clockwise bisector (snd lineHalves)
                 then endpoint $ pointSlopeLength (midpoint l') (lineSlope m) (-distance)
                 else endpoint $ pointSlopeLength (midpoint l') (lineSlope m) distance
      numIntersections = length $ intersectionsToOrigin contour l

-- FIXME: assumes we are in positive space.
intersectionsToOrigin :: Contour -> Line -> [Point2]
intersectionsToOrigin contour l = saneIntersections l0 $ filter (/= l) $ contourLines contour
  where
    -- A line to the origin.
    l0 = lineFromEndpoints (midpoint l) (Point2 (-1,-1))
    contourLines (PointSequence c) = makeLinesLooped c
    -- a filter for results that make sense.
    saneIntersections :: Line -> [Line] -> [Point2]
    saneIntersections l1 ls = mapMaybe saneIntersectionOf ls
      where
        saneIntersectionOf :: Line -> Maybe Point2
        saneIntersectionOf l2 = saneIntersection (lineIntersection l1 l2)
          where
            saneIntersection :: Intersection -> Maybe Point2
            saneIntersection (IntersectsAt p2) = Just p2
            saneIntersection NoIntersection = Nothing
            saneIntersection Parallel = Nothing
            saneIntersection AntiParallel = Nothing
    -- FIXME: fix these cases.
    --          saneIntersection Collinear = Nothing
    --          saneIntersection LColinear _ _ = Nothing
    --          saneIntersection (HitStartPointL2 p2) = Just p2
    --          saneIntersection (HitEndPointL2 p2) = Just p2
            saneIntersection res = error $ "insane result of intersecting a line (" <> show l1 <> ") with it's bisector: " <> show l2 <> "\nwhen finding an inner perimeter point on contour " <> show ls <> "\n" <> show res <> "\n"

