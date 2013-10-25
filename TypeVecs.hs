{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveGeneric #-}

module TypeVecs
       ( Vec ( unVec )
       , tvlength
       , tvlengthT
       , (<++>)
--       , (|>)
--       , (<|)
       , mkSeq
       , mkVec
       , unsafeSeq
       , unsafeVec
       , tvsplit
       , tvhead
       , tvzipWith
       , tvinit
       , tvtail
       , tvlast
       , tvreplicate
       )
       where

import Data.TypeLevel.Num.Ops ( Add, Succ )
import Data.TypeLevel.Num.Sets

import Data.Foldable ( Foldable )
import Data.Traversable ( Traversable )
import qualified Data.Foldable as F
import qualified Data.Sequence as S
import qualified Data.Vector as V

import GHC.Generics

import Vectorize ( GVectorize(..), Vectorize(..) )


-- length-indexed vectors using phantom types
newtype Vec s a = MkVec {unVec :: S.Seq a} deriving (Eq, Ord, Functor, Foldable, Traversable, Generic1)

instance Nat n => Vectorize (Vec n) where
  vectorize = V.fromList . F.toList . unVec
  devectorize = mkSeq . S.fromList . V.toList
  empty = ret
    where
      ret = mkSeq $ S.replicate k ()
      k = tvlength ret

      --V.fromList . F.toList . unVec
instance Nat n => GVectorize (Vec n) where
  gvectorize = V.fromList . F.toList . unVec
  gdevectorize = mkSeq . S.fromList . V.toList
  gempty = ret
    where
      ret = mkSeq $ S.replicate k ()
      k = tvlength ret

--infixr 5 <|
--infixl 5 |>
--(<|) :: Succ n np1 => a -> Vec n a -> Vec np1 a
--(<|) x (Vec xs) = Vec (V.cons x xs)
--
--(|>) :: Succ n np1 => Vec n a -> a -> Vec np1 a
--(|>) (Vec xs) x = Vec (V.snoc xs x)

-- create a Vec with a runtime check
unsafeVec :: Nat s => V.Vector a -> Vec s a
unsafeVec = unsafeSeq . S.fromList . V.toList

unsafeSeq :: Nat s => S.Seq a -> Vec s a
unsafeSeq xs = case MkVec xs of
  ret -> let staticLen = tvlength ret
             dynLen = S.length xs
         in if staticLen == dynLen
            then ret
            else error $ "unsafeVec: static/dynamic length mismatch: " ++
                 "static: " ++ show staticLen ++ ", dynamic: " ++ show  dynLen

mkVec :: Nat s => V.Vector a -> Vec s a
--mkVec = MkVec . S.fromList . V.toList
mkVec = unsafeVec -- lets just run the check every time for now

mkSeq :: Nat s => S.Seq a -> Vec s a
--mkSeq = MkVec
mkSeq = unsafeSeq -- lets just run the check every time for now

tvlength :: Nat s => Vec s a -> Int
tvlength = toInt . (undefined `asLengthOf`)

tvlengthT :: Vec s a -> s
tvlengthT = (undefined `asLengthOf`)

asLengthOf :: s -> Vec s a -> s
asLengthOf x _ = x

-- split into two
--vsplit :: (Nat i, i :<=: s, Sub s i si) => i -> Vec s a -> (Vec i a, Vec si a)
tvsplit :: (Nat i, Nat si, Add i si s) => i -> Vec s a -> (Vec i a, Vec si a)
tvsplit i v = (mkSeq x, mkSeq y)
  where
    (x,y) = S.splitAt (toInt i) (unVec v)

tvzipWith :: Nat s => (a -> b -> c) -> Vec s a -> Vec s b -> Vec s c
tvzipWith f x y = mkSeq (S.zipWith f (unVec x) (unVec y))

tvhead :: Pos s => Vec s a -> a
tvhead x = case S.viewl (unVec x) of
  y S.:< _ -> y
  S.EmptyL -> error "vhead: empty"

tvtail :: (Succ sm1 s) => Vec s a -> Vec sm1 a
tvtail x = case S.viewl (unVec x) of
  _ S.:< ys -> mkSeq ys
  S.EmptyL -> error "vtail: empty"

tvinit :: (Succ sm1 s) => Vec s a -> Vec sm1 a
tvinit x = case S.viewr (unVec x) of
  ys S.:> _ -> mkSeq ys
  S.EmptyR -> error "vinit: empty"

tvlast :: Pos s => Vec s a -> a
tvlast x = case S.viewr (unVec x) of
  _ S.:> y -> y
  S.EmptyR -> error "vlast: empty"

tvreplicate :: Nat n => n -> a -> Vec n a
tvreplicate n = mkSeq . (S.replicate (toInt n))

-- concatenate two vectors
infixr 5 <++>
(<++>) :: (Nat s1, Nat s2, Add s1 s2 s3) => Vec s1 a -> Vec s2 a -> Vec s3 a
(<++>) x y = mkSeq $ (unVec x) S.>< (unVec y)

instance Show a => Show (Vec s a) where
  showsPrec _ = showV . F.toList . unVec
    where
      showV []      = showString "<>"
      showV (x:xs)  = showChar '<' . shows x . showl xs
        where
          showl []      = showChar '>'
          showl (y:ys)  = showChar ',' . shows y . showl ys
