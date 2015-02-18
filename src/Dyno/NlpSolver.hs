{-# OPTIONS_GHC -Wall #-}
{-# Language ScopedTypeVariables #-}
{-# Language PackageImports #-}
{-# Language KindSignatures #-}
{-# Language GeneralizedNewtypeDeriving #-}

module Dyno.NlpSolver
       ( NlpSolver
       , SXElement
       , runNlpSolver
       , runNlp
         -- * solve
       , solve
       , solve'
         -- * inputs
       , setX0
       , setP
       , setLbx
       , setUbx
       , setLbg
       , setUbg
       , setLamX0
       , setLamG0
       , getX0
       , getP
       , getLbx
       , getUbx
       , getLbg
       , getUbg
       , getLamX0
       , getLamG0
         -- * outputs
       , getF
       , getX
       , getG
       , getLamX
       , getLamG
       , getStat
       , getNlpOut'
         -- * options
       , Op.Opt(..)
       , setOption
       , reinit
         -- * other
       , MonadIO
       , liftIO
       , generateAndCompile
       ) where

import Data.Proxy ( Proxy(..) )
import System.Process ( callProcess, showCommandForUser )
import Control.Exception ( AsyncException( UserInterrupt ), try )
import Control.Concurrent ( forkIO, newEmptyMVar, takeMVar, putMVar )
import Control.Applicative ( Applicative(..) )
import Control.Monad ( when, void )
import "mtl" Control.Monad.Reader ( MonadIO(..), MonadReader(..), ReaderT(..) )
import Data.Maybe ( fromMaybe )
import Data.IORef ( newIORef, readIORef, writeIORef )
import Data.Vector ( Vector )
import qualified Data.Vector as V

import Casadi.Core.Enums ( InputOutputScheme(..) )
import qualified Casadi.Core.Classes.Function as C
import qualified Casadi.Core.Classes.NlpSolver as C
import qualified Casadi.Core.Classes.GenericType as C
import qualified Casadi.Core.Classes.IOInterfaceFunction as C

import Casadi.Callback ( makeCallback )
import Casadi.DMatrix ( DMatrix, ddata )
import Casadi.Function ( Function, externalFunction )
import qualified Casadi.Option as Op
import qualified Casadi.GenericC as Gen
import Casadi.SharedObject ( soInit )
import Casadi.CMatrix ( CMatrix )
import qualified Casadi.CMatrix as CM

import Dyno.View.Unsafe.View ( unJ, mkJ )

import Dyno.SXElement ( SXElement )
import Dyno.Vectorize ( Id(..) )
import Dyno.View.JV ( JV )
import Dyno.View.View ( View(..), J, unzipJ, fmapJ )
import Dyno.View.Symbolic ( Symbolic, sym, mkScheme, mkFunction )
import Dyno.View.Viewable ( Viewable )
import Dyno.Nlp ( Nlp'(..), NlpOut'(..) )
import Dyno.NlpScaling ( ScaleFuns(..), scaledFG, mkScaleFuns )
import Dyno.Solvers ( Solver(..) )

type VD a = J a (Vector Double)
type VMD a = J a (Vector (Maybe Double))

getStat :: String -> NlpSolver x p g C.GenericType
getStat name = do
  nlpState <- ask
  liftIO $ C.function_getStat (isSolver nlpState) name

setInput ::
  View xg
  => (ScaleFuns x g DMatrix -> (J xg DMatrix -> J xg DMatrix))
  -> (NlpState x g -> Int)
  -> String
  -> J xg (V.Vector Double)
  -> NlpSolver x p g ()
setInput scaleFun getLen name x0 = do
  nlpState <- ask
  let x = unJ $ scaleFun (isScale nlpState) $ mkJ $ CM.fromDVector (unJ x0)
  let nActual = (CM.size1 x, CM.size2 x)
      nTypeLevel = (getLen nlpState, 1)
  when (nTypeLevel /= nActual) $ error $
    name ++ " dimension mismatch, " ++ show nTypeLevel ++
    " (type-level) /= " ++ show nActual ++ " (given)"
  liftIO $ C.ioInterfaceFunction_setInput__0 (isSolver nlpState) x name
  return ()

setX0 :: forall x p g. View x => VD x -> NlpSolver x p g ()
setX0 = setInput xToXBar isNx "x0"

inf :: Double
inf = read "Infinity"

toLb :: View x => J x (Vector (Maybe Double)) -> J x (Vector Double)
toLb = fmapJ (fromMaybe (-inf))

toUb :: View x => J x (Vector (Maybe Double)) -> J x (Vector Double)
toUb = fmapJ (fromMaybe   inf )

setLbx :: View x => VMD x -> NlpSolver x p g ()
setLbx = setInput xToXBar isNx "lbx" . toLb

setUbx :: View x => VMD x -> NlpSolver x p g ()
setUbx = setInput xToXBar isNx "ubx" . toUb

setLbg :: View g => VMD g -> NlpSolver x p g ()
setLbg = setInput gToGBar isNg "lbg" . toLb

setUbg :: View g => VMD g -> NlpSolver x p g ()
setUbg = setInput gToGBar isNg "ubg" . toUb

setP :: View p => VD p -> NlpSolver x p g ()
setP = setInput (const id) isNp "p"

setLamX0 :: View x => VD x -> NlpSolver x p g ()
setLamX0 = setInput lamXToLamXBar isNx "lam_x0"

setLamG0 :: View g => VD g -> NlpSolver x p g ()
setLamG0 = setInput lamGToLamGBar isNg "lam_g0"

getInput ::
  View xg
  => (ScaleFuns x g DMatrix -> (J xg DMatrix -> J xg DMatrix))
  -> String -> NlpSolver x p g (J xg (Vector Double))
getInput scaleFun name = do
  nlpState <- ask
  dmat <- liftIO $ C.ioInterfaceFunction_input__0 (isSolver nlpState) name
  let scale = scaleFun (isScale nlpState)
  return (mkJ $ ddata $ unJ $ scale (mkJ dmat))

getX0 :: View x => NlpSolver x p g (VD x)
getX0 = getInput xbarToX "x0"

getLbx :: View x => NlpSolver x p g (VD x)
getLbx = getInput xbarToX "lbx"

getUbx :: View x => NlpSolver x p g (VD x)
getUbx = getInput xbarToX "ubx"

getLbg :: View g => NlpSolver x p g (VD g)
getLbg = getInput gbarToG "lbg"

getUbg :: View g => NlpSolver x p g (VD g)
getUbg = getInput gbarToG "ubg"

getP :: View p => NlpSolver x p g (VD p)
getP = getInput (const id) "p"

getLamX0 :: View x => NlpSolver x p g (VD x)
getLamX0 = getInput lamXBarToLamX "lam_x0"

getLamG0 :: View g => NlpSolver x p g (VD g)
getLamG0 = getInput lamGBarToLamG "lam_g0"

getOutput ::
  View xg
  => (ScaleFuns x g DMatrix -> (J xg DMatrix -> J xg DMatrix))
  -> String -> NlpSolver x p g (J xg (Vector Double))
getOutput scaleFun name = do
  nlpState <- ask
  dmat <- liftIO $ C.ioInterfaceFunction_output__0 (isSolver nlpState) name
  let scale = scaleFun (isScale nlpState)
  return (mkJ $ ddata $ unJ $ scale (mkJ dmat))

getF :: NlpSolver x p g (VD (JV Id))
getF = getOutput fbarToF "f"

getX :: View x => NlpSolver x p g (VD x)
getX = getOutput xbarToX "x"

getG :: View g => NlpSolver x p g (VD g)
getG = getOutput gbarToG "g"

getLamX :: View x => NlpSolver x p g (VD x)
getLamX = getOutput lamXBarToLamX "lam_x"

getLamG :: View g => NlpSolver x p g (VD g)
getLamG = getOutput lamGBarToLamG "lam_g"


setOption :: Gen.GenericC a => String -> a -> NlpSolver x p g ()
setOption name val = do
  nlpState <- ask
  let nlp = isSolver nlpState
  liftIO $ Op.setOption nlp name val


reinit :: NlpSolver x p g ()
reinit = do
  nlpState <- ask
  let nlp = isSolver nlpState
  liftIO $ soInit nlp

-- | solve with current inputs, return success or failure code
solve :: NlpSolver x p g (Either String String)
solve = do
  nlpState <- ask
  let nlp = isSolver nlpState
  solveStatus <- liftIO $ do

    stop <- newEmptyMVar -- mvar that will be filled when nlp finishes
    _ <- forkIO (C.function_evaluate nlp >> putMVar stop ())
    -- wait until nlp finishes
    ret <- try (takeMVar stop)
    case ret of Right () -> return () -- no exceptions
                Left UserInterrupt -> do -- got ctrl-C
                  isInterrupt nlpState -- tell nlp to stop iterations
                  _ <- takeMVar stop -- wait for nlp to return
                  return ()
                Left _ -> void (takeMVar stop) -- don't handle this one
    genericStat <- C.function_getStat nlp "return_status"
    strStat <- Gen.fromGeneric genericStat :: IO (Maybe String)
    intStat <- Gen.fromGeneric genericStat :: IO (Maybe Int)
    statDescription <- Gen.getDescription genericStat
    case strStat of
      Just strStat' -> return strStat'
      Nothing -> case intStat of
        Just intStat' -> return (show intStat')
        Nothing -> error $ "nlp solver error: return status is not {string,int}, it's " ++
                   statDescription

  return $ if solveStatus `elem` isSuccessCodes nlpState
    then Right solveStatus
    else Left solveStatus

-- | solve with current inputs, return lots of info on success, or message on failure
solve' :: (View x, View g) => NlpSolver x p g (Either String String, NlpOut' x g (Vector Double))
solve' = do
  solveStatus <- solve
  nlpOut <- getNlpOut'
  return (solveStatus, nlpOut)

getNlpOut' :: (View x, View g) => NlpSolver x p g (NlpOut' x g (Vector Double))
getNlpOut' = do
  fopt <- getF
  xopt <- getX
  gopt <- getG
  lamXOpt <- getLamX
  lamGOpt <- getLamG
  let nlpOut = NlpOut' { fOpt' = fopt
                       , xOpt' = xopt
                       , gOpt' = gopt
                       , lambdaXOpt' = lamXOpt
                       , lambdaGOpt' = lamGOpt
                       }
  return nlpOut


data NlpState (x :: * -> *) (g :: * -> *) =
  NlpState
  { isNx :: Int
  , isNg :: Int
  , isNp :: Int
  , isSolver :: C.NlpSolver
  , isInterrupt :: IO ()
  , isSuccessCodes :: [String]
  , isScale :: ScaleFuns x g DMatrix
  }
newtype NlpSolver (x :: * -> *) (p :: * -> *) (g :: * -> *) a =
  NlpSolver (ReaderT (NlpState x g) IO a)
  deriving ( Functor
           , Applicative
           , Monad
           , MonadReader (NlpState x g)
           , MonadIO
           )

generateAndCompile :: String -> Function -> IO Function
generateAndCompile name f = do
  putStrLn $ "generating " ++ name ++ ".c"
--  writeFile (name ++ ".c") (generateCode f)
  C.function_generateCode__3 f (name ++ ".c") True
  let cmd = "clang"
      args = ["-fPIC","-shared","-Wall","-Wno-unused-variable",name++".c","-o",name++".so"]
  putStrLn (showCommandForUser cmd args)
  callProcess cmd args
  externalFunction ("./"++name++".so")

runNlpSolver ::
  forall x p g a s .
  (View x, View p, View g, Symbolic s)
  => Solver
  -> (J x s -> J p s -> (J (JV Id) s, J g s))
  -> Maybe (J x (Vector Double))
  -> Maybe (J g (Vector Double))
  -> Maybe Double
  -> Maybe (J x (Vector Double) -> IO Bool)
  -> NlpSolver x p g a
  -> IO a
runNlpSolver solverStuff nlpFun scaleX scaleG scaleF callback' (NlpSolver nlpMonad) = do
  inputsX <- sym "x"
  inputsP <- sym "p"

  let scale :: forall sfa . (CMatrix sfa, Viewable sfa) => ScaleFuns x g sfa
      scale = mkScaleFuns scaleX scaleG scaleF

  let (obj, g) = scaledFG scale nlpFun inputsX inputsP

  let inputsXMat = unJ inputsX
      inputsPMat = unJ inputsP
      objMat     = unJ obj
      gMat       = unJ g

  inputScheme <- mkScheme SCHEME_NLPInput [("x", inputsXMat), ("p", inputsPMat)]
  outputScheme <- mkScheme SCHEME_NLPOutput [("f", objMat), ("g", gMat)]
  nlp <- mkFunction "nlp" inputScheme outputScheme
--  Op.setOption nlp "verbose" True
  mapM_ (\(l,Op.Opt o) -> Op.setOption nlp l o) (functionOptions solverStuff)
  soInit nlp

  functionCall solverStuff nlp

--  let eval 0 = error "finished"
--      eval k = do
--        putStrLn "setting input"
--        ioInterfaceFunction_setInput''' nlp (unJ nlpX0') (0::Int)
--        putStrLn $ "evaluating " ++ show k
--        C.function_evaluate nlp
--        eval (k-1 :: Int)
--  eval (300::Int)
--  casadiOptions_stopProfiling
--  _ <- error "done"


--  jac_sparsity <- C.function_jacSparsity nlp 0 1 True False
--  C.sparsity_spyMatlab jac_sparsity "jac_sparsity_reorder.m"


  solver <- C.nlpSolver__0 (solverName solverStuff) nlp

  -- add callback if user provides it
  intref <- newIORef False
  let cb function' = do
        callbackRet <- case callback' of
          Nothing -> return True
          Just callback -> do
            xval <- fmap (mkJ . ddata . unJ . xbarToX scale . mkJ . CM.dense) $
                    C.ioInterfaceFunction_output__2 function' 0
            callback xval
        interrupt <- readIORef intref
        return $ if callbackRet && not interrupt then 0 else fromIntegral (solverInterruptCode solverStuff)
  casadiCallback <- makeCallback cb >>= C.genericType__0
  Op.setOption solver "iteration_callback" casadiCallback
--  grad_f <- gradient nlp 0 0
--  soInit grad_f
--  jac_g <- jacobian nlp 0 1 True False
--  soInit jac_g
--
--  let eval 0 = error "finished"
--      eval k = do
--        putStrLn "setting input"
--        ioInterfaceFunction_setInput''' jac_g (unJ nlpX0') (0::Int)
--        putStrLn $ "evaluating " ++ show k
--        C.function_evaluate jac_g
--        eval (k-1 :: Int)
--  eval (40::Int)

--  nlp' <- generateAndCompile "nlp" nlp
--  grad_f' <- generateAndCompile "grad_f" grad_f
--  jac_g' <- generateAndCompile "jac_g" jac_g
--  _ <- error "lal"
--  Op.setOption solver "grad_f" grad_f'
--  Op.setOption solver "jac_g" jac_g'

  -- set all the user options
  mapM_ (\(l,Op.Opt o) -> Op.setOption solver l o) (defaultOptions solverStuff ++ options solverStuff)
  soInit solver

  let proxy :: J f b -> Proxy f
      proxy = const Proxy

      nlpState = NlpState { isNx = size (proxy inputsX)
                          , isNp = size (proxy inputsP)
                          , isNg = size (proxy g)
                          , isSolver = solver
                          , isInterrupt = writeIORef intref True
                          , isSuccessCodes = successCodes solverStuff
                          , isScale = scale
                          }
  liftIO $ runReaderT nlpMonad nlpState


-- | set all inputs, handle scaling, and let the user run a NlpMonad
runNlp ::
  (View x, View p, View g, Symbolic a)
  => Solver
  -> Nlp' x p g a -> Maybe (J x (Vector Double) -> IO Bool)
  -> NlpSolver x p g b
  -> IO b
runNlp solverStuff nlp callback runMe =
  runNlpSolver solverStuff (nlpFG' nlp) (nlpScaleX' nlp) (nlpScaleG' nlp) (nlpScaleF' nlp) callback $ do
    let (lbx,ubx) = unzipJ (nlpBX' nlp)
        (lbg,ubg) = unzipJ (nlpBG' nlp)

    setX0 (nlpX0' nlp)
    setP (nlpP' nlp)
    setLbx lbx
    setUbx ubx
    setLbg lbg
    setUbg ubg
    case nlpLamX0' nlp of
      Just lam -> setLamX0 lam
      Nothing -> return ()
    case nlpLamG0' nlp of
      Just lam -> setLamG0 lam
      Nothing -> return ()
    runMe
