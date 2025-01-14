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

{- The purpose of this file is to hold facet based arithmatic. -}

-- for adding Generic and NFData to Facet.
{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}

module Graphics.Slicer.Math.Tri (Tri(Tri), sidesOf, shiftTri, triIntersects) where

import Prelude (Eq, (<$>), ($), error, (==), (&&), Show)

import Data.List.Extra(nubOrd)

import Data.Maybe(catMaybes, Maybe(Just, Nothing))

import Data.Bifunctor (bimap)

import GHC.Generics (Generic)

import Control.DeepSeq (NFData)

import Graphics.Slicer.Definitions(ℝ)

import Graphics.Slicer.Math.Definitions (Point2, Point3, addPoints, flatten, zOf)

import Graphics.Slicer.Math.Line (pointAtZValue)

newtype Tri = Tri((Point3, Point3),(Point3, Point3),(Point3, Point3))
  deriving (Eq, Generic, NFData, Show)

-- Shift a tri by the vector p
shiftTri :: Point3 -> Tri -> Tri
shiftTri p (Tri (s1,s2,s3)) = Tri (bimap (addPoints p) (addPoints p) s1,
                                   bimap (addPoints p) (addPoints p) s2,
                                   bimap (addPoints p) (addPoints p) s3
                                  )

-- allow us to use mapping functions against the tuple of sides.
sidesOf :: Tri -> [(Point3,Point3)]
sidesOf (Tri (a,b,c)) = [a,b,c]

-- determine where a tri intersects a plane at a given z value
triIntersects :: ℝ -> Tri -> Maybe (Point2,Point2)
triIntersects v f = res matchingEdges
  where
    res []        = trimIntersections $ nubOrd $ catMaybes intersections
    res [oneEdge] = Just oneEdge
    res _         = Nothing
    intersections = (`pointAtZValue` v) <$> sidesOf f
    -- Get rid of the case where a tri intersects the plane at one point
    trimIntersections :: [Point2] -> Maybe (Point2,Point2)
    trimIntersections []      = Nothing
    trimIntersections [_]     = Nothing
    trimIntersections [p1,p2] = Just (p1,p2)
    -- ignore triangles that are exactly aligned with the plane.
    trimIntersections [_,_,_] = Nothing
    trimIntersections _ = error "unpossible!"
    matchingEdges = catMaybes $ edgeOnPlane <$> sidesOf f
      where
        edgeOnPlane :: (Point3,Point3) -> Maybe (Point2,Point2)
        edgeOnPlane (start,stop) = if zOf start == zOf stop && zOf start == v
                                   then Just (flatten start, flatten stop)
                                   else Nothing
