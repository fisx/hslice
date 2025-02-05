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
 -
 - You should have received a copy of the GNU Affero General Public License
 - along with this program.  If not, see <http://www.gnu.org/licenses/>.
 -}

-- To treat literal strings as Text
{-# LANGUAGE OverloadedStrings #-}

-- for NFData.
{-# LANGUAGE DeriveGeneric, DeriveAnyClass #-}

module Graphics.Slicer.Machine.GCode (GCode(GCMarkOuterWallStart, GCMarkInnerWallStart, GCMarkInfillStart, GCMarkLayerStart, GCMarkSupportStart), cookExtrusions, make3DTravelGCode, make2DTravelGCode, addFeedRate, gcodeForContour, gcodeForInfill, gcodeToText) where

import GHC.Generics (Generic)

import Prelude (Eq, Int, ($), tail, init, zipWith, concat, head, last, (<>), show, error, (++), otherwise, (==), length, (/=), fst, pi, (/), (*), pure, toRational, (.), fromRational, (<$>), (+), div, Bool)

import Data.ByteString (ByteString)

import Data.ByteString.Char8 (spanEnd)

import Control.Parallel.Strategies (using, rseq, parListChunk)

import Data.ByteString.UTF8 (fromString)

import Data.Double.Conversion.ByteString (toFixed)

import Control.DeepSeq (NFData)

import Graphics.Slicer.Definitions(ℝ, ℝ2, ℝ3, ℕ, Fastℕ, fromFastℕ)

import Graphics.Slicer.Math.Contour (pointsOfContour)

import Graphics.Slicer.Math.Definitions (Point3(Point3), Point2(Point2), Contour, distance, roundToFifth)

import Graphics.Slicer.Math.Line (LineSeg(LineSeg), endpoint)

import Graphics.Slicer.Math.Slicer (accumulateValues)

import Graphics.Slicer.Machine.StateM (StateM, getEPos, setEPos)

import Graphics.Slicer.Mechanics.Definitions (Extruder, filamentWidth)

default (ℕ, Fastℕ, ℝ)

---------------------------------------------------------
--------------------- GCode Generation ------------------
---------------------------------------------------------

-- | A single gcode statement.
data GCode =
    GCMove2 { _startPoint2 :: ℝ2, _stopPoint2 :: ℝ2 }
  | GCMove3 { _startPoint3 :: ℝ3, _stopPoint3 :: ℝ3 }
  | GCFeedRate { _rate :: ℝ, _code :: GCode }
  | GCExtrude2 { _startPoint2 :: ℝ2, _stopPoint2 :: ℝ2, _ePos :: ℝ }
  | GCExtrude3 { _startPoint3 :: ℝ3, _stopPoint3 :: ℝ3, _ePos :: ℝ }
  | GCRawExtrude2 { _startPoint2 :: ℝ2, _stopPoint2 :: ℝ2, _extrusion :: RawExtrude }
  | GCRawExtrude3 { _startPoint3 :: ℝ3, _stopPoint3 :: ℝ3, _extrusion :: RawExtrude }
  | GCMarkLayerStart { _layerNumber :: Fastℕ }
  | GCMarkInnerWallStart
  | GCMarkOuterWallStart
  | GCMarkSupportStart
  | GCMarkInfillStart
  deriving (Eq, Generic, NFData)

-- | The dimensions of a section of material to be extruded.
data RawExtrude = RawExtrude { _pathLength :: ℝ, _pathWidth :: ℝ, _pathHeight :: ℝ }
  deriving (Eq, Generic, NFData)

-- | Calculate the extrusion values for all of the GCodes that extrude.
cookExtrusions :: Extruder -> [GCode] -> Fastℕ -> StateM [GCode]
cookExtrusions extruder gcodes threads = do
  currentPos <- fromRational <$> getEPos
  let
    ePoses = [currentPos+amount | amount <- accumulateValues extrusionAmounts]
    extrusionAmounts = [calculateExtrusion gcode | gcode <- gcodes] `using` parListChunk (div (length gcodes) (fromFastℕ threads)) rseq
  setEPos . toRational $ last ePoses
  pure $ applyExtrusions gcodes ePoses
  where
    applyExtrusions :: [GCode] -> [ℝ] -> [GCode]
    applyExtrusions = zipWith applyExtrusion
    applyExtrusion :: GCode -> ℝ -> GCode
    applyExtrusion (GCRawExtrude2 startPoint stopPoint _) ePos = GCExtrude2 startPoint stopPoint ePos
    applyExtrusion (GCRawExtrude3 startPoint stopPoint _) ePos = GCExtrude3 startPoint stopPoint ePos
    -- FIXME: should these two generate warnings?
    applyExtrusion (GCExtrude2 startPoint stopPoint _) ePos = GCExtrude2 startPoint stopPoint ePos
    applyExtrusion (GCExtrude3 startPoint stopPoint _) ePos = GCExtrude3 startPoint stopPoint ePos
    applyExtrusion gcode _ = gcode
    calculateExtrusion :: GCode -> ℝ
    calculateExtrusion (GCRawExtrude2 _ _ (RawExtrude pathLength pathWidth pathHeight)) =
      pathWidth * pathHeight * (2 / filamentDia) * pathLength / pi
    calculateExtrusion (GCRawExtrude3 _ _ (RawExtrude pathLength pathWidth pathHeight)) =
      pathWidth * pathHeight * (2 / filamentDia) * pathLength / pi
    calculateExtrusion _ = 0
    filamentDia = filamentWidth extruder


-- | Construct a GCode to travel to a point without extruding (2D)
make2DTravelGCode :: Point2 -> Point2 -> GCode
make2DTravelGCode (Point2 (x1,y1)) (Point2 (x2,y2)) = GCMove2 (x1,y1) (x2,y2)

-- | Construct a GCode to travel to a point without extruding (3D)
make3DTravelGCode :: Point3 -> Point3 -> GCode
make3DTravelGCode (Point3 p1) (Point3 p2) = GCMove3 p1 p2

-- | Construct a GCode to travel to a point while extruding.
make2DExtrudeGCode :: ℝ -> ℝ -> Point2 -> Point2 -> GCode
make2DExtrudeGCode pathThickness pathWidth p1@(Point2 (x1,y1)) p2@(Point2 (x2,y2)) = GCRawExtrude2 (x1, y1) (x2, y2) (RawExtrude pathLength pathWidth pathThickness)
  where
    pathLength = distance p1 p2

-- | Add a feedrate to a piece of gcode.
addFeedRate :: ℝ -> GCode -> GCode
addFeedRate = GCFeedRate

-- | Render a value to ByteString, in the precision that is suitable to use in a gcode file. drops trailing zeroes, and the decimal, if there is no fractional component.
posIze :: ℝ -> ByteString
posIze pos
  | pos == 0 = "0"
  | otherwise = fst $ spanEnd (== '.') $ fst $ spanEnd (== '0') $ toFixed 5 pos

(~/=) :: ℝ -> ℝ -> Bool
(~/=) a b = roundToFifth a /= roundToFifth b

-- | Render a GCode into a piece of text, ready to print. Only handles 'cooked' gcode, that has had extrusion values calculated.
gcodeToText :: GCode -> ByteString
gcodeToText (GCFeedRate f (GCMove2 (x1,y1) (x2,y2))) = "G0 F" <> posIze f <> " " <> (if x1 ~/= x2 then "X" <> posIze x2 <> " " else "") <> (if y1 ~/= y2 then "Y" <> posIze y2 <> " " else "")
gcodeToText (GCFeedRate f wtf) = error "applying feedrate " <> posIze f <> " to something other than a GCmove2: " <> gcodeToText wtf
gcodeToText (GCMove2 (x1,y1) (x2,y2)) = "G0 " <> (if x1 ~/= x2 then "X" <> posIze x2 <> " " else "") <> (if y1 ~/= y2 then "Y" <> posIze y2 <> " " else "")
gcodeToText (GCMove3 (x1,y1,z1) (x2,y2,z2)) = "G0 " <> (if x1 ~/= x2 then "X" <> posIze x2 <> " " else "") <> (if y1 ~/= y2 then "Y" <> posIze y2 <> " " else "") <> (if z1 ~/= z2 then "Z" <> posIze z2 else "")
gcodeToText (GCExtrude2 (x1,y1) (x2,y2) e) = "G1 " <> (if x1 ~/= x2 then "X" <> posIze x2 <> " " else "") <> (if y1 ~/= y2 then "Y" <> posIze y2 <> " " else "") <> "E" <> posIze e
gcodeToText (GCExtrude3 (x1,y1,z1) (x2,y2,z2) e) = "G1 " <> (if x1 ~/= x2 then "X" <> posIze x2 <> " " else "") <> (if y1 ~/= y2 then "Y" <> posIze y2 <> " " else "") <> (if z1 ~/= z2 then "Z" <> posIze z2 <> " " else "") <> "E" <> posIze e
gcodeToText GCRawExtrude2 {} = error "Attempting to generate gcode for a 2D extrude command that has not yet been cooked."
gcodeToText GCRawExtrude3 {} = error "Attempting to generate gcode for a 3D extrude command that has not yet been cooked."
-- The current layer count, where 1 == the bottom layer of the object being printed. rafts are represented as negative layers.
gcodeToText (GCMarkLayerStart layerNo) = ";LAYER:" <> fromString (show (fromFastℕ layerNo :: Int))
-- perimeters on the inside of the object. may contact the infill, or an outer paremeter, but will not be exposed on the outside of the object.
gcodeToText GCMarkInnerWallStart = ";TYPE:WALL-INNER"
-- a perimeter on the outside of the object. may contact the infill, or an inside paremeter.
gcodeToText GCMarkOuterWallStart = ";TYPE:WALL-OUTER"
-- Marker indicating the following gcode commands are part of the support, and do not touch the object or the build plate. think: the sparsely generated back-and-forth 
gcodeToText GCMarkSupportStart = ";TYPE:SUPPORT"
-- The interior of an object. should only contact inner parameters, skin, or outer paremeters.
gcodeToText GCMarkInfillStart = ";TYPE:FILL"

-- | Generate GCode for a given contour.
-- Assumes the printer is already at the first point of the contour.
gcodeForContour :: ℝ -> ℝ -> Contour -> [GCode]
gcodeForContour lh pathWidth contour = zipWith (make2DExtrudeGCode lh pathWidth) contourPoints (tail contourPoints) ++ [make2DExtrudeGCode lh pathWidth (last contourPoints) (head contourPoints)]
  where
    contourPoints = pointsOfContour contour

-- | For each group of lines, generate gcode for the segments, with move commands between them.
gcodeForInfill :: ℝ -> ℝ -> [[LineSeg]] -> [GCode]
gcodeForInfill _ _ [] = []
gcodeForInfill lh pathWidth lineGroups = concat $ renderLineSegGroup (head lineGroups) : zipWith (\group1 group2 -> moveBetweenLineSegGroups group1 group2 ++ renderLineSegGroup group2) (init lineGroups) (tail lineGroups)
  where
    -- FIXME: this should be a single gcode. why are we getting empty line groups given to us?
    moveBetweenLineSegGroups :: [LineSeg] -> [LineSeg] -> [GCode]
    moveBetweenLineSegGroups [] g2 = error $ "given empty line group?\n" <> show g2 <> "\n"
    moveBetweenLineSegGroups g1 [] = error $ "line group empty when finding line group following " <> show g1 <> "\n"
    moveBetweenLineSegGroups g1 g2 = [moveBetween (last g1) (head g2)]
    renderLineSegGroup :: [LineSeg] -> [GCode]
    renderLineSegGroup [] = []
    renderLineSegGroup group = renderSegment (head group) : concat (zipWith (\ l1 l2 -> moveBetween l1 l2 : [renderSegment l2]) (init group) (tail group))
    moveBetween :: LineSeg -> LineSeg -> GCode
    moveBetween l1 (LineSeg startPointl2 _) = make2DTravelGCode (endpoint l1) startPointl2
    renderSegment :: LineSeg -> GCode
    renderSegment ln@(LineSeg startPoint _) = make2DExtrudeGCode lh pathWidth startPoint $ endpoint ln

----------------------------------------------------
------------------ FIXED STRINGS -------------------
----------------------------------------------------
-- FIXME: put these in the right places.
{-
-- The beginning of a sequence of gcodes instructing the printer to place a skirt around the object.
skirtStartGCode :: [Text]
skirtStartGCode = [";TYPE:SKIRT"]
-- The time consumed by the gcode in the file being generated thus far. generated by cura after each layer transition.
timeMarkerGCode :: Text
timeMarkerGCode = ";TIME_ELAPSED:"
-- Part of the support, may touch the build plate, or be part of the last two layers before support contacts the object.
-- support-interface is generated with 100% infill.
supportInterfaceStartGCode :: [Text]
supportInterfaceStartGCode = [";TYPE:SUPPORT-INTERFACE"]
-- The top / bottom surfaces of an object.
skinStartGCode :: [Text]
skinStartGCode = [";TYPE:SKIN"]
-- A gcode identifying the source mesh that is being sliced.
meshStartGCode :: Text
meshStartGCode = ";MESH:"
-}

