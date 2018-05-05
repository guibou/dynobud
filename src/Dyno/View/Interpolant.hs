{-# OPTIONS_GHC -Wall -fno-cse -fno-full-laziness #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}

module Dyno.View.Interpolant
       ( Interpolant(..)
       ) where

import Control.Monad ( void, when )
import Data.List ( intercalate )
import Data.Map ( Map )
import Data.Int ( Int32 )
import qualified Data.Vector as V
import Foreign.C.String
import Foreign.C.Types
import Foreign.ForeignPtr ( ForeignPtr, newForeignPtr, withForeignPtr )
import Foreign.Ptr ( FunPtr, Ptr )
import Foreign.Marshal.Alloc ( free )
import Foreign.Marshal.Array ( mallocArray, newArray, peekArray, withArray )
import Linear ( V2(..), V3(..), V4(..) )
import System.IO.Unsafe ( unsafePerformIO )

import qualified Casadi.Interpolant as C
import Casadi.GenericType ( GType )
import Casadi.DM ( DM )
import Casadi.MX ( MX )

import Dyno.View.Fun ( Fun(..), callSym, callDM, checkFunDimensions )
import Dyno.View.Vectorize ( Vectorize(vectorize, devectorize') )
import Dyno.View.View ( J, JV, S )
import Dyno.View.M ( vcat, vsplit )

data RawInterpolant
foreign import ccall unsafe "interpolant.hpp new_interpolant" c_newInterpolant
  :: Ptr (Ptr CDouble) -> Int32 -> Ptr Int32 -> Ptr CDouble -> Int32 -> CString -> IO (Ptr RawInterpolant)

foreign import ccall unsafe "interpolant.hpp eval_interpolant" c_evalInterpolant
  :: Ptr RawInterpolant -> Ptr CDouble -> Ptr CDouble -> IO ()

foreign import ccall unsafe "interpolant.hpp &delete_interpolant" c_deleteInterpolant
  :: FunPtr (Ptr RawInterpolant-> IO ())

data CInterpolant = CInterpolant Int Int (ForeignPtr RawInterpolant)

newInterpolant :: String -> [[Double]] -> [Double] -> IO CInterpolant
newInterpolant lookupMode grid values = do
  let ndims = length grid
      gridLengths = map length grid
      nvalues = length values

      gridLengthProd = product gridLengths

      noutputs :: Int
      noutputs = nvalues `div` gridLengthProd

  void $ when (noutputs * gridLengthProd /= nvalues) $
    error $
    intercalate "\n"
    [ "newInterpolant:"
    , "grid lengths: " ++ show gridLengths
    , "# values: " ++ show nvalues
    , "noutputs: " ++ show noutputs
    ]

  gridPtrs <- mapM (newArray . map realToFrac) grid :: IO [Ptr CDouble]
  gridPtr <- newArray gridPtrs :: IO (Ptr (Ptr CDouble))
  gridLengthsPtr <- newArray (map fromIntegral gridLengths) :: IO (Ptr Int32)
  valuesPtr <- newArray (map realToFrac values) :: IO (Ptr CDouble)
  raw <- withCString lookupMode $
         c_newInterpolant gridPtr (fromIntegral ndims) gridLengthsPtr valuesPtr (fromIntegral nvalues)
  free gridLengthsPtr
  free valuesPtr
  free gridPtr
  mapM_ free gridPtrs

  CInterpolant ndims noutputs <$> newForeignPtr c_deleteInterpolant raw

evalInterpolant :: CInterpolant -> [Double] -> IO [Double]
evalInterpolant (CInterpolant ndims noutputs raw) inputs
  | length inputs /= ndims =
      error $
      intercalate "\n"
      [ "interpolant called with wrong number of values"
      , "expected dimension: " ++ show ndims
      , "given dimensions: " ++ show (length inputs)
      ]
  | otherwise = do
      outputPtr <- mallocArray noutputs :: IO (Ptr CDouble)
      withArray (map realToFrac inputs) $ \inputPtr ->
        withForeignPtr raw $ \obj ->
        c_evalInterpolant obj inputPtr outputPtr
      ret <- peekArray noutputs outputPtr :: IO [CDouble]
      free outputPtr
      return (map realToFrac ret)


arrangeValues2 ::
  forall f0 f1 g
  . ( Vectorize f0, Traversable f0
    , Vectorize f1
    , Vectorize g
    )
  => f0 Double -> f1 Double
  -> f0 (f1 (g Double))
  -> (V.Vector (V.Vector Double), V.Vector Double)
arrangeValues2 grid0 grid1 values0 = (grid, concatValues vectorizedValues)
  where
    -- transpose values
    values :: f1 (f0 (g Double))
    values = sequenceA values0

    vectorizedValues :: V.Vector (g Double)
    vectorizedValues = V.concatMap vectorize (vectorize values)

    grid :: V.Vector (V.Vector Double)
    grid = V.fromList [vectorize grid0, vectorize grid1]

arrangeValues3 ::
  forall f0 f1 f2 g
  . ( Vectorize f0, Traversable f0
    , Vectorize f1, Traversable f1
    , Vectorize f2
    , Vectorize g
    )
  => f0 Double -> f1 Double -> f2 Double
  -> f0 (f1 (f2 (g Double)))
  -> (V.Vector (V.Vector Double), V.Vector Double)
arrangeValues3 grid0 grid1 grid2 values0 = (grid, concatValues vectorizedValues)
  where
    -- transpose values
    values :: f2 (f1 (f0 (g Double)))
    values = v3
      where
        v0 :: f0 (f1 (f2 (g Double)))
        v0 = values0

        v1 :: f1 (f0 (f2 (g Double)))
        v1 = sequenceA v0

        v2 :: f1 (f2 (f0 (g Double)))
        v2 = fmap sequenceA v1

        v3 :: f2 (f1 (f0 (g Double)))
        v3 = sequenceA v2

    vectorizedValues :: V.Vector (g Double)
    vectorizedValues = V.concatMap vectorize $ V.concatMap vectorize (vectorize values)

    grid :: V.Vector (V.Vector Double)
    grid = V.fromList [vectorize grid0, vectorize grid1, vectorize grid2]


arrangeValues4 ::
  forall f0 f1 f2 f3 g
  . ( Vectorize f0, Traversable f0
    , Vectorize f1, Traversable f1
    , Vectorize f2, Traversable f2
    , Vectorize f3
    , Vectorize g
    )
  => f0 Double -> f1 Double -> f2 Double -> f3 Double
  -> f0 (f1 (f2 (f3 (g Double))))
  -> (V.Vector (V.Vector Double), V.Vector Double)
arrangeValues4 grid0 grid1 grid2 grid3 values0 = (grid, concatValues vectorizedValues)
  where
    -- transpose values
    values :: f3 (f2 (f1 (f0 (g Double))))
    values = v6
      where
        v0 :: f0 (f1 (f2 (f3 (g Double))))
        v0 = values0

        v1 :: f1 (f0 (f2 (f3 (g Double))))
        v1 = sequenceA v0

        v2 :: f1 (f2 (f0 (f3 (g Double))))
        v2 = fmap sequenceA v1

        v3 :: f1 (f2 (f3 (f0 (g Double))))
        v3 = fmap (fmap sequenceA) v2

        v4 :: f2 (f1 (f3 (f0 (g Double))))
        v4 = sequenceA v3

        v5 :: f2 (f3 (f1 (f0 (g Double))))
        v5 = fmap sequenceA v4

        v6 :: f3 (f2 (f1 (f0 (g Double))))
        v6 = sequenceA v5

    vectorizedValues :: V.Vector (g Double)
    vectorizedValues = V.concatMap vectorize $ V.concatMap vectorize $ V.concatMap vectorize (vectorize values)

    grid :: V.Vector (V.Vector Double)
    grid = V.fromList [vectorize grid0, vectorize grid1, vectorize grid2, vectorize grid3]

concatValues :: Vectorize g => V.Vector (g Double) -> V.Vector Double
concatValues = V.concatMap vectorize

{-# NOINLINE mxInterpolant1 #-}
mxInterpolant1 :: forall g a .
                  Vectorize g
               => String -> String -> V.Vector (Double, g Double) -> Map String GType
               -> (Fun S (J (JV g)) -> S a -> IO (J (JV g) a))
               -> (S a -> J (JV g) a)
mxInterpolant1 name solver gridAndValues opts callIt = interpolate
  where
    uncheckedFun :: Fun S (J (JV g))
    uncheckedFun = Fun $ C.interpolant name solver (V.singleton grid) (concatValues values) opts

    fun :: Fun S (J (JV g))
    fun = case checkFunDimensions uncheckedFun of
      Right _ -> uncheckedFun
      Left err -> error $ "error making interpolant1 " ++ name ++ ": " ++ err

    grid :: V.Vector Double
    values :: V.Vector (g Double)
    (grid, values) = V.unzip gridAndValues

    {-# NOINLINE interpolate #-}
    interpolate :: S a -> J (JV g) a
    interpolate x = unsafePerformIO (callIt fun x)


{-# NOINLINE mxInterpolant2 #-}
mxInterpolant2
  :: forall f0 f1 g a .
     ( Vectorize f0, Traversable f0
     , Vectorize f1
     , Vectorize g
     )
  => String -> String
  -> f0 Double -> f1 Double
  -> f0 (f1 (g Double))
  -> Map String GType
  -> (Fun (J (JV V2)) (J (JV g)) -> J (JV V2) a -> IO (J (JV g) a))
  -> (J (JV V2) a -> J (JV g) a)
mxInterpolant2 name solver grid0 grid1 values0 opts callIt = interpolate
  where
    uncheckedFun :: Fun (J (JV V2)) (J (JV g))
    uncheckedFun = Fun $ C.interpolant name solver grid vectorizedValues opts

    fun :: Fun (J (JV V2)) (J (JV g))
    fun = case checkFunDimensions uncheckedFun of
      Right _ -> uncheckedFun
      Left err -> error $ "error making interpolant2 " ++ name ++ ": " ++ err

    grid :: V.Vector (V.Vector Double)
    vectorizedValues :: V.Vector Double
    (grid, vectorizedValues) = arrangeValues2 grid0 grid1 values0

    {-# NOINLINE interpolate #-}
    interpolate :: J (JV V2) a -> J (JV g) a
    interpolate x = unsafePerformIO (callIt fun x)

mxInterpolant3 ::
  forall f0 f1 f2 g a
  . ( Vectorize f0, Traversable f0
    , Vectorize f1, Traversable f1
    , Vectorize f2
    , Vectorize g
    )
  => String -> String
  -> f0 Double -> f1 Double -> f2 Double
  -> f0 (f1 (f2 (g Double)))
  -> Map String GType
  -> (Fun (J (JV V3)) (J (JV g)) -> J (JV V3) a -> IO (J (JV g) a))
  -> (J (JV V3) a -> J (JV g) a)
mxInterpolant3 name solver grid0 grid1 grid2 values0 opts callIt = interpolate
  where
    grid :: V.Vector (V.Vector Double)
    vectorizedValues :: V.Vector Double
    (grid, vectorizedValues) = arrangeValues3 grid0 grid1 grid2 values0

    uncheckedFun :: Fun (J (JV V3)) (J (JV g))
    uncheckedFun = Fun $ C.interpolant name solver grid vectorizedValues opts

    fun :: Fun (J (JV V3)) (J (JV g))
    fun = case checkFunDimensions uncheckedFun of
      Right _ -> uncheckedFun
      Left err -> error $ "error making interpolant3 " ++ name ++ ": " ++ err

    {-# NOINLINE interpolate #-}
    interpolate :: J (JV V3) a -> J (JV g) a
    interpolate x = unsafePerformIO (callIt fun x)


mxInterpolant4 ::
  forall f0 f1 f2 f3 g a
  . ( Vectorize f0, Traversable f0
    , Vectorize f1, Traversable f1
    , Vectorize f2, Traversable f2
    , Vectorize f3
    , Vectorize g
    )
  => String -> String
  -> f0 Double -> f1 Double -> f2 Double -> f3 Double
  -> f0 (f1 (f2 (f3 (g Double))))
  -> Map String GType
  -> (Fun (J (JV V4)) (J (JV g)) -> J (JV V4) a -> IO (J (JV g) a))
  -> (J (JV V4) a -> J (JV g) a)
mxInterpolant4 name solver grid0 grid1 grid2 grid3 values0 opts callIt = interpolate
  where
    grid :: V.Vector (V.Vector Double)
    vectorizedValues :: V.Vector Double
    (grid, vectorizedValues) = arrangeValues4 grid0 grid1 grid2 grid3 values0

    uncheckedFun :: Fun (J (JV V4)) (J (JV g))
    uncheckedFun = Fun $ C.interpolant name solver grid vectorizedValues opts

    fun :: Fun (J (JV V4)) (J (JV g))
    fun = case checkFunDimensions uncheckedFun of
      Right _ -> uncheckedFun
      Left err -> error $ "error making interpolant4 " ++ name ++ ": " ++ err

    {-# NOINLINE interpolate #-}
    interpolate :: J (JV V4) a -> J (JV g) a
    interpolate x = unsafePerformIO (callIt fun x)


{-# NOINLINE makeCInterpolant1 #-}
makeCInterpolant1 :: forall g .
                     Vectorize g
                  => String -> V.Vector (Double, g Double) -> IO (Double -> g Double)
makeCInterpolant1 lookupName gridAndValues = do
  let (grid, values) = V.unzip gridAndValues

  interpolant <- newInterpolant lookupName [V.toList grid] (V.toList (concatValues values))
  let {-# NOINLINE interpolate #-}
      interpolate :: Double -> g Double
      interpolate x = unsafePerformIO $ do
        ret <- evalInterpolant interpolant [x]
        case devectorize' (V.fromList ret) of
          Right r -> return r
          Left err -> error $ "interpolant1 error devectorizing outputs: " ++ err

  return interpolate


{-# NOINLINE makeCInterpolant2 #-}
makeCInterpolant2 ::
  forall f0 f1 g
  . ( Vectorize f0, Traversable f0
    , Vectorize f1
    , Vectorize g
    )
  => String
  -> f0 Double -> f1 Double
  -> f0 (f1 (g Double))
  -> IO (V2 Double -> g Double)
makeCInterpolant2 lookupName grid0 grid1 values0 = do
  let grid :: V.Vector (V.Vector Double)
      vectorizedValues :: V.Vector Double
      (grid, vectorizedValues) = arrangeValues2 grid0 grid1 values0
  interpolant <- newInterpolant lookupName (map V.toList (V.toList grid)) (V.toList vectorizedValues)
  let {-# NOINLINE interpolate #-}
      interpolate :: V2 Double -> g Double
      interpolate (V2 x y) = unsafePerformIO $ do
        ret <- evalInterpolant interpolant [x, y]
        case devectorize' (V.fromList ret) of
          Right r -> return r
          Left err -> error $ "interpolant2 error devectorizing outputs: " ++ err

  return interpolate

{-# NOINLINE makeCInterpolant3 #-}
makeCInterpolant3 ::
  forall f0 f1 f2 g
  . ( Vectorize f0, Traversable f0
    , Vectorize f1, Traversable f1
    , Vectorize f2
    , Vectorize g
    )
  => String
  -> f0 Double -> f1 Double -> f2 Double
  -> f0 (f1 (f2 (g Double)))
  -> IO (V3 Double -> g Double)
makeCInterpolant3 lookupName grid0 grid1 grid2 values0 = do
  let grid :: V.Vector (V.Vector Double)
      vectorizedValues :: V.Vector Double
      (grid, vectorizedValues) = arrangeValues3 grid0 grid1 grid2 values0
  interpolant <- newInterpolant lookupName (map V.toList (V.toList grid)) (V.toList vectorizedValues)
  let {-# NOINLINE interpolate #-}
      interpolate :: V3 Double -> g Double
      interpolate (V3 x y z) = unsafePerformIO $ do
        ret <- evalInterpolant interpolant [x, y, z]
        case devectorize' (V.fromList ret) of
          Right r -> return r
          Left err -> error $ "interpolant3 error devectorizing outputs: " ++ err

  return interpolate


{-# NOINLINE makeCInterpolant4 #-}
makeCInterpolant4 ::
  forall f0 f1 f2 f3 g
  . ( Vectorize f0, Traversable f0
    , Vectorize f1, Traversable f1
    , Vectorize f2, Traversable f2
    , Vectorize f3
    , Vectorize g
    )
  => String
  -> f0 Double -> f1 Double -> f2 Double -> f3 Double
  -> f0 (f1 (f2 (f3 (g Double))))
  -> IO (V4 Double -> g Double)
makeCInterpolant4 lookupName grid0 grid1 grid2 grid3 values0 = do
  let grid :: V.Vector (V.Vector Double)
      vectorizedValues :: V.Vector Double
      (grid, vectorizedValues) = arrangeValues4 grid0 grid1 grid2 grid3 values0
  interpolant <- newInterpolant lookupName (map V.toList (V.toList grid)) (V.toList vectorizedValues)
  let {-# NOINLINE interpolate #-}
      interpolate :: V4 Double -> g Double
      interpolate (V4 x y z w) = unsafePerformIO $ do
        ret <- evalInterpolant interpolant [x, y, z, w]
        case devectorize' (V.fromList ret) of
          Right r -> return r
          Left err -> error $ "interpolant4 error devectorizing outputs: " ++ err

  return interpolate


class Interpolant a where
  makeInterpolant1 :: Vectorize g
                   => String -> String
                   -> V.Vector (Double, g Double)
                   -> IO (a -> g a)
  makeInterpolant2 :: ( Vectorize f0, Traversable f0
                      , Vectorize f1
                      , Vectorize g
                      )
                   => String -> String -> f0 Double -> f1 Double
                   -> f0 (f1 (g Double))
                   -> IO (V2 a -> g a)
  makeInterpolant3 :: ( Vectorize f0, Traversable f0
                      , Vectorize f1, Traversable f1
                      , Vectorize f2
                      , Vectorize g
                      )
                   => String -> String -> f0 Double -> f1 Double -> f2 Double
                   -> f0 (f1 (f2 (g Double)))
                   -> IO (V3 a -> g a)
  makeInterpolant4 :: ( Vectorize f0, Traversable f0
                      , Vectorize f1, Traversable f1
                      , Vectorize f2, Traversable f2
                      , Vectorize f3
                      , Vectorize g
                      )
                   => String -> String -> f0 Double -> f1 Double -> f2 Double -> f3 Double
                   -> f0 (f1 (f2 (f3 (g Double))))
                   -> IO (V4 a -> g a)

instance Interpolant Double where
  makeInterpolant1 _ = makeCInterpolant1
  makeInterpolant2 _ = makeCInterpolant2
  makeInterpolant3 _ = makeCInterpolant3
  makeInterpolant4 _ = makeCInterpolant4

callSymIO :: (Vectorize f, Vectorize g) => Fun (J (JV f)) (J (JV g)) -> J (JV f) MX -> IO (J (JV g) MX)
callSymIO fun x = return (callSym fun x)

instance Interpolant (S MX) where
  makeInterpolant1 name solver gridAndValues = return (vsplit . callFun)
    where
      callFun = mxInterpolant1 name solver gridAndValues mempty callSymIO
  makeInterpolant2 name solver grid0 grid1 values = return (vsplit . callFun . vcat)
    where
      callFun = mxInterpolant2 name solver grid0 grid1 values mempty callSymIO
  makeInterpolant3 name solver grid0 grid1 grid2 values = return (vsplit . callFun . vcat)
    where
      callFun = mxInterpolant3 name solver grid0 grid1 grid2 values mempty callSymIO
  makeInterpolant4 name solver grid0 grid1 grid2 grid3 values = return (vsplit . callFun . vcat)
    where
      callFun = mxInterpolant4 name solver grid0 grid1 grid2 grid3 values mempty callSymIO

instance Interpolant (S DM) where
  makeInterpolant1 name solver gridAndValues = return (vsplit . callFun)
    where
      callFun = mxInterpolant1 name solver gridAndValues mempty callDM
  makeInterpolant2 name solver grid0 grid1 values = return (vsplit . callFun . vcat)
    where
      callFun = mxInterpolant2 name solver grid0 grid1 values mempty callDM
  makeInterpolant3 name solver grid0 grid1 grid2 values = return (vsplit . callFun . vcat)
    where
      callFun = mxInterpolant3 name solver grid0 grid1 grid2 values mempty callDM
  makeInterpolant4 name solver grid0 grid1 grid2 grid3 values = return (vsplit . callFun . vcat)
    where
      callFun = mxInterpolant4 name solver grid0 grid1 grid2 grid3 values mempty callDM
