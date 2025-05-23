{-# OPTIONS_GHC -Wunused-imports #-}

{-| Primitive functions, such as addition on builtin integers.
-}

module Agda.TypeChecking.Primitive
       ( module Agda.TypeChecking.Primitive.Base
       , module Agda.TypeChecking.Primitive.Cubical
       , module Agda.TypeChecking.Primitive
       ) where

import Data.Char
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Maybe
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word

import qualified Agda.Interaction.Options.Lenses as Lens

import Agda.Syntax.Common hiding (Nat)
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Generic (TermLike(..))
import Agda.Syntax.Internal.MetaVars
import Agda.Syntax.Literal

import Agda.TypeChecking.Monad hiding (getConstInfo, typeOfConst)
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Reduce.Monad as Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.TypeChecking.Level

import Agda.TypeChecking.Quote (quoteTermWithKit, quoteTypeWithKit, quoteDomWithKit, quotingKit)
import Agda.TypeChecking.Primitive.Base
import Agda.TypeChecking.Primitive.Cubical
import Agda.TypeChecking.Warnings

import Agda.Utils.Char
import Agda.Utils.Float
import Agda.Utils.Functor
import Agda.Utils.List
import Agda.Utils.Maybe (fromMaybeM)
import Agda.Utils.Monad
import Agda.Syntax.Common.Pretty
import Agda.Utils.Singleton
import Agda.Utils.Size

import Agda.Utils.Impossible

-- Haskell type to Agda type

newtype Nat = Nat { unNat :: Integer }
            deriving (Eq, Ord, Num, Enum, Real)

-- In GHC > 7.8 deriving Integral causes an unnecessary toInteger
-- warning.
instance Integral Nat where
  toInteger = unNat
  quotRem (Nat a) (Nat b) = (Nat q, Nat r)
    where (q, r) = quotRem a b

instance TermLike Nat where
  traverseTermM _ = pure
  foldTerm _      = mempty

instance Pretty Nat where
  pretty = pretty . toInteger

newtype Lvl = Lvl { unLvl :: Integer }
  deriving (Eq, Ord)

instance Pretty Lvl where
  pretty = pretty . unLvl

class PrimType a where
  primType :: a -> TCM Type

  -- This used to be a catch-all instance `PrimType a => PrimTerm a` which required UndecidableInstances.
  -- Now we declare the instances separately, but enforce the catch-all-ness with a superclass constraint on PrimTerm.
  default primType :: PrimTerm a => a -> TCM Type
  primType _ = el $ primTerm (undefined :: a)

class PrimType a => PrimTerm a where
  primTerm :: a -> TCM Term

instance (PrimType a, PrimType b) => PrimType (a -> b)
instance (PrimType a, PrimType b) => PrimTerm (a -> b) where
  primTerm _ = unEl <$> (primType (undefined :: a) --> primType (undefined :: b))

instance (PrimType a, PrimType b) => PrimType (a, b)
instance (PrimType a, PrimType b) => PrimTerm (a, b) where
  primTerm _ = do
    sigKit <- fromMaybeM (typeError $ NoBindingForBuiltin BuiltinSigma) getSigmaKit
    let sig = Def (sigmaName sigKit) []
    a'       <- primType (undefined :: a)
    b'       <- primType (undefined :: b)
    Type la  <- pure $ getSort a'
    Type lb  <- pure $ getSort b'
    pure sig <#> pure (Level la)
             <#> pure (Level lb)
             <@> pure (unEl a')
             <@> pure (nolam $ unEl b')

instance PrimType Integer
instance PrimTerm Integer where primTerm _ = primInteger

instance PrimType Word64
instance PrimTerm Word64  where primTerm _ = primWord64

instance PrimType Bool
instance PrimTerm Bool    where primTerm _ = primBool

instance PrimType Char
instance PrimTerm Char    where primTerm _ = primChar

instance PrimType Double
instance PrimTerm Double  where primTerm _ = primFloat

instance PrimType Text
instance PrimTerm Text    where primTerm _ = primString

instance PrimType Nat
instance PrimTerm Nat     where primTerm _ = primNat

instance PrimType Lvl
instance PrimTerm Lvl     where primTerm _ = primLevel

instance PrimType QName
instance PrimTerm QName   where primTerm _ = primQName

instance PrimType MetaId
instance PrimTerm MetaId  where primTerm _ = primAgdaMeta

instance PrimType Type
instance PrimTerm Type    where primTerm _ = primAgdaTerm

instance PrimType Fixity'
instance PrimTerm Fixity' where primTerm _ = primFixity

instance PrimTerm a => PrimType [a]
instance PrimTerm a => PrimTerm [a] where
  primTerm _ = list (primTerm (undefined :: a))

instance PrimTerm a => PrimType (Maybe a)
instance PrimTerm a => PrimTerm (Maybe a) where
  primTerm _ = tMaybe (primTerm (undefined :: a))

instance PrimTerm a => PrimType (IO a)
instance PrimTerm a => PrimTerm (IO a) where
  primTerm _ = io (primTerm (undefined :: a))

-- From Agda term to Haskell value

class ToTerm a where
  toTerm  :: TCM (a -> ReduceM Term)

toTermTCM :: ToTerm a => TCM (a -> TCM Term)
toTermTCM = (runReduceM .) <$> toTerm

instance ToTerm Nat     where toTerm = return $ pure . Lit . LitNat . toInteger
instance ToTerm Word64  where toTerm = return $ pure . Lit . LitWord64
instance ToTerm Lvl     where toTerm = return $ pure . Level . ClosedLevel . unLvl
instance ToTerm Double  where toTerm = return $ pure . Lit . LitFloat
instance ToTerm Char    where toTerm = return $ pure . Lit . LitChar
instance ToTerm Text    where toTerm = return $ pure . Lit . LitString
instance ToTerm QName   where toTerm = return $ pure . Lit . LitQName
instance ToTerm MetaId  where
  toTerm = do
    top <- fromMaybe __IMPOSSIBLE__ <$> currentTopLevelModule
    return $ pure . Lit . LitMeta top

instance ToTerm Integer where
  toTerm = do
    pos     <- primIntegerPos
    negsuc  <- primIntegerNegSuc
    fromNat <- toTerm @Nat
    let intToTerm = fromNat . fromIntegral @Integer
    let fromInt n | n >= 0    = apply1 pos    <$> intToTerm n
                  | otherwise = apply1 negsuc <$> intToTerm (-n - 1)
    return fromInt

instance ToTerm Bool where
  toTerm = do
    true  <- primTrue
    false <- primFalse
    return $ \b -> pure $ if b then true else false

instance ToTerm Term where
  toTerm = do quoteTermWithKit <$> quotingKit

instance ToTerm (Dom Type) where
  toTerm = do quoteDomWithKit <$> quotingKit

instance ToTerm Type where
  toTerm = quoteTypeWithKit <$> quotingKit

instance ToTerm ArgInfo where
  toTerm = do
    info <- primArgArgInfo
    vis  <- primVisible
    hid  <- primHidden
    ins  <- primInstance
    rel  <- primRelevant
    irr  <- primIrrelevant
    return $ \ i -> pure $ info `applys`
      [ case getHiding i of
          NotHidden  -> vis
          Hidden     -> hid
          Instance{} -> ins
      , case getRelevance i of
          Relevant        {} -> rel
          Irrelevant      {} -> irr
          ShapeIrrelevant {} -> rel
      ]

instance ToTerm Fixity' where
  toTerm = (. theFixity) <$> toTerm

instance ToTerm Fixity where
  toTerm = do
    lToTm  <- toTerm
    aToTm  <- toTerm
    fixity <- primFixityFixity
    return $ \ Fixity{fixityAssoc = a, fixityLevel = l} ->
      apply2 fixity <$> aToTm a <*> lToTm l

instance ToTerm Associativity where
  toTerm = do
    lassoc <- primAssocLeft
    rassoc <- primAssocRight
    nassoc <- primAssocNon
    return $ \ a -> pure $
      case a of
        NonAssoc   -> nassoc
        LeftAssoc  -> lassoc
        RightAssoc -> rassoc

instance ToTerm Blocker where
  toTerm = do
    all <- primAgdaBlockerAll
    any <- primAgdaBlockerAny
    meta <- primAgdaBlockerMeta
    lists <- buildList
    metaTm <- toTerm
    let go (UnblockOnAny xs)    = apply1 any . lists <$> mapM go (Set.toList xs)
        go (UnblockOnAll xs)    = apply1 all . lists <$> mapM go (Set.toList xs)
        go (UnblockOnMeta m)    = apply1 meta <$> metaTm m
        go (UnblockOnDef _)     = __IMPOSSIBLE__
        go (UnblockOnProblem _) = __IMPOSSIBLE__
    pure go

instance ToTerm FixityLevel where
  toTerm = do
    iToTm <- toTerm
    related   <- primPrecRelated
    unrelated <- primPrecUnrelated
    return $ \ p ->
      case p of
        Unrelated -> pure unrelated
        Related n -> apply1 related <$> iToTm n

instance (ToTerm a, ToTerm b) => ToTerm (a, b) where
  toTerm = do
    sigKit <- fromMaybe __IMPOSSIBLE__ <$> getSigmaKit
    let con = Con (sigmaCon sigKit) ConOSystem []
    fromA <- toTerm
    fromB <- toTerm
    pure $ \ (a, b) -> apply2 con <$> fromA a <*> fromB b

-- | @buildList A ts@ builds a list of type @List A@. Assumes that the terms
--   @ts@ all have type @A@.
buildList :: TCM ([Term] -> Term)
buildList = do
    nil'  <- primNil
    cons' <- primCons
    let nil       = nil'
        cons x xs = cons' `applys` [x, xs]
    return $ foldr cons nil

instance ToTerm a => ToTerm [a] where
  toTerm = do
    mkList <- buildList
    fromA  <- toTerm
    return $ mkList <.> mapM fromA

instance ToTerm a => ToTerm (Maybe a) where
  toTerm = do
    nothing <- primNothing
    just    <- primJust
    fromA   <- toTerm
    return $ maybe (pure nothing) (apply1 just <.> fromA)

-- From Haskell value to Agda term

type FromTermFunction a = Arg Term ->
                          ReduceM (Reduced (MaybeReduced (Arg Term)) a)

class FromTerm a where
  fromTerm :: TCM (FromTermFunction a)

instance FromTerm Integer where
  fromTerm = do
    Con pos _    [] <- primIntegerPos
    Con negsuc _ [] <- primIntegerNegSuc
    toNat         <- fromTerm :: TCM (FromTermFunction Nat)
    return $ \ v -> do
      b <- reduceB' v
      let v'  = ignoreBlocking b
          arg = (<$ v')
      case unArg (ignoreBlocking b) of
        Con c ci [Apply u]
          | c == pos    ->
            redBind (toNat u)
              (\ u' -> pure $ notReduced $ arg $ Con c ci [Apply $ ignoreReduced u']) $ \ n ->
            redReturn $ fromIntegral n
          | c == negsuc ->
            redBind (toNat u)
              (\ u' -> pure $ notReduced $ arg $ Con c ci [Apply $ ignoreReduced u']) $ \ n ->
            redReturn $ fromIntegral $ -n - 1
        _ -> return $ NoReduction (reduced b)

instance FromTerm Nat where
  fromTerm = fromLiteral $ \case
    LitNat n -> Just $ fromInteger n
    _ -> Nothing

instance FromTerm Word64 where
  fromTerm = fromLiteral $ \ case
    LitWord64 n -> Just n
    _ -> Nothing

instance FromTerm Lvl where
  fromTerm = fromReducedTerm $ \case
    Level (ClosedLevel n) -> Just $ Lvl n
    _ -> Nothing

instance FromTerm Double where
  fromTerm = fromLiteral $ \case
    LitFloat x -> Just x
    _ -> Nothing

instance FromTerm Char where
  fromTerm = fromLiteral $ \case
    LitChar c -> Just c
    _ -> Nothing

instance FromTerm Text where
  fromTerm = fromLiteral $ \case
    LitString s -> Just s
    _ -> Nothing

instance FromTerm QName where
  fromTerm = fromLiteral $ \case
    LitQName x -> Just x
    _ -> Nothing

instance FromTerm MetaId where
  fromTerm = fromLiteral $ \case
    LitMeta _ x -> Just x
    _ -> Nothing

instance FromTerm Bool where
    fromTerm = do
        true  <- primTrue
        false <- primFalse
        fromReducedTerm $ \case
            t   | t =?= true  -> Just True
                | t =?= false -> Just False
                | otherwise   -> Nothing
        where
            a =?= b = a === b
            Def x [] === Def y []   = x == y
            Con x _ [] === Con y _ [] = x == y
            Var n [] === Var m []   = n == m
            _        === _          = False

instance (ToTerm a, FromTerm a) => FromTerm [a] where
  fromTerm = do
    nil   <- isCon <$> primNil
    cons  <- isCon <$> primCons
    toA   <- fromTerm
    mkList nil cons toA <$> toTerm
    where
      isCon (Lam _ b)   = isCon $ absBody b
      isCon (Con c _ _) = c
      isCon v           = __IMPOSSIBLE__

      mkList nil cons toA fromA t = do
        b <- reduceB' t
        let t = ignoreBlocking b
        let arg = (<$ t)
        case unArg t of
          Con c ci []
            | c == nil  -> return $ YesReduction NoSimplification []
          Con c ci es
            | c == cons, Just [x,xs] <- allApplyElims es ->
              redBind (toA x)
                  (\x' -> pure $ notReduced $ arg $ Con c ci (map Apply [ignoreReduced x',xs])) $ \y ->
              redBind
                  (mkList nil cons toA fromA xs)
                  (\ xsR -> do
                    yTm <- fromA y
                    pure $ for xsR $ \xs' -> arg $ Con c ci (map Apply [defaultArg yTm, xs'])) $ \ys ->
              redReturn (y : ys)
          _ -> return $ NoReduction (reduced b)

instance FromTerm a => FromTerm (Maybe a) where
  fromTerm = do
    nothing <- isCon <$> primNothing
    just    <- isCon <$> primJust
    toA     <- fromTerm
    return $ \ t -> do
      let arg = (<$ t)
      b <- reduceB' t
      let t = ignoreBlocking b
      case unArg t of
        Con c ci []
          | c == nothing -> return $ YesReduction NoSimplification Nothing
        Con c ci es
          | c == just, Just [x] <- allApplyElims es ->
            redBind (toA x)
              (\ x' -> pure $ notReduced $ arg $ Con c ci [Apply (ignoreReduced x')])
              (redReturn . Just)
        _ -> return $ NoReduction (reduced b)

    where
      isCon (Lam _ b)   = isCon $ absBody b
      isCon (Con c _ _) = c
      isCon v           = __IMPOSSIBLE__


fromReducedTerm :: (Term -> Maybe a) -> TCM (FromTermFunction a)
fromReducedTerm f = return $ \t -> do
    b <- reduceB' t
    case f $ unArg (ignoreBlocking b) of
        Just x  -> return $ YesReduction NoSimplification x
        Nothing -> return $ NoReduction (reduced b)

fromLiteral :: (Literal -> Maybe a) -> TCM (FromTermFunction a)
fromLiteral f = fromReducedTerm $ \case
    Lit lit -> f lit
    _       -> Nothing

-- | @mkPrimInjective@ takes two Set0 @a@ and @b@ and a function @f@ of type
--   @a -> b@ and outputs a primitive internalizing the fact that @f@ is injective.
mkPrimInjective :: Type -> Type -> QName -> TCM PrimitiveImpl
mkPrimInjective a b qn = do
  -- Define the type
  eqName <- primEqualityName
  let lvl0     = ClosedLevel 0
  let eq a t u = El (Type lvl0) <$> pure (Def eqName []) <#> pure (Level lvl0)
                                <#> pure (unEl a) <@> t <@> u
  let f    = pure (Def qn [])
  ty <- nPi "t" (pure a) $ nPi "u" (pure a) $
              (eq b (f <@> varM 1) (f <@> varM 0))
          --> (eq a (      varM 1) (      varM 0))

    -- Get the constructor corresponding to BUILTIN REFL
  refl <- getRefl

  -- Implementation: when the equality argument reduces to refl so does the primitive.
  -- If the user want the primitive to reduce whenever the two values are equal (no
  -- matter whether the equality is refl), they can combine it with @eraseEquality@.
  return $ PrimImpl ty $ primFun __IMPOSSIBLE__ 3 $ \ ts -> do
    let t  = headWithDefault __IMPOSSIBLE__ ts
    let eq = unArg $ fromMaybe __IMPOSSIBLE__ $ lastMaybe ts
    reduce' eq >>= \case
      Con{} -> redReturn $ refl t
      _     -> return $ NoReduction $ map notReduced ts

-- | Converts 'MetaId's to natural numbers.

metaToNat :: MetaId -> Nat
metaToNat m =
  fromIntegral (moduleNameHash $ metaModule m) * 2 ^ 64 +
  fromIntegral (metaId m)

primMetaToNatInjective :: TCM PrimitiveImpl
primMetaToNatInjective = do
  meta  <- primType (undefined :: MetaId)
  nat   <- primType (undefined :: Nat)
  toNat <- primFunName <$> getPrimitive PrimMetaToNat
  mkPrimInjective meta nat toNat

primCharToNatInjective :: TCM PrimitiveImpl
primCharToNatInjective = do
  char  <- primType (undefined :: Char)
  nat   <- primType (undefined :: Nat)
  toNat <- primFunName <$> getPrimitive PrimCharToNat
  mkPrimInjective char nat toNat

primStringToListInjective :: TCM PrimitiveImpl
primStringToListInjective = do
  string <- primType (undefined :: Text)
  chars  <- primType (undefined :: String)
  toList <- primFunName <$> getPrimitive PrimStringToList
  mkPrimInjective string chars toList

primStringFromListInjective :: TCM PrimitiveImpl
primStringFromListInjective = do
  chars  <- primType (undefined :: String)
  string <- primType (undefined :: Text)
  fromList <- primFunName <$> getPrimitive PrimStringFromList
  mkPrimInjective chars string fromList

primWord64ToNatInjective :: TCM PrimitiveImpl
primWord64ToNatInjective =  do
  word  <- primType (undefined :: Word64)
  nat   <- primType (undefined :: Nat)
  toNat <- primFunName <$> getPrimitive PrimWord64ToNat
  mkPrimInjective word nat toNat

primFloatToWord64Injective :: TCM PrimitiveImpl
primFloatToWord64Injective = do
  float  <- primType (undefined :: Double)
  mword  <- primType (undefined :: Maybe Word64)
  toWord <- primFunName <$> getPrimitive PrimFloatToWord64
  mkPrimInjective float mword toWord

primQNameToWord64sInjective :: TCM PrimitiveImpl
primQNameToWord64sInjective = do
  name    <- primType (undefined :: QName)
  words   <- primType (undefined :: (Word64, Word64))
  toWords <- primFunName <$> getPrimitive PrimQNameToWord64s
  mkPrimInjective name words toWords

getRefl :: TCM (Arg Term -> Term)
getRefl = do
  -- BUILTIN REFL maybe a constructor with one (the principal) argument or only parameters.
  -- Get the ArgInfo of the principal argument of refl.
  con@(Con rf ci []) <- primRefl
  minfo <- fmap (setOrigin Inserted) <$> getReflArgInfo rf
  pure $ case minfo of
    Just ai -> Con rf ci . (:[]) . Apply . setArgInfo ai
    Nothing -> const con

-- | @primEraseEquality : {a : Level} {A : Set a} {x y : A} -> x ≡ y -> x ≡ y@
primEraseEquality :: TCM PrimitiveImpl
primEraseEquality = do
  -- primEraseEquality is incompatible with --without-K
  -- We raise an error warning if --safe is set and a mere warning otherwise
  whenM withoutKOption $
    ifM (Lens.getSafeMode <$> commandLineOptions)
      {- then -} (warning SafeFlagWithoutKFlagPrimEraseEquality)
      {- else -} (warning WithoutKFlagPrimEraseEquality)
  -- Get the name and type of BUILTIN EQUALITY
  eq   <- primEqualityName
  eqTy <- defType <$> getConstInfo eq
  -- E.g. @eqTy = eqTel → Set a@ where @eqTel = {a : Level} {A : Set a} (x y : A)@.
  TelV eqTel eqCore <- telView eqTy
  let eqSort = case unEl eqCore of
        Sort s -> s
        _      -> __IMPOSSIBLE__

  -- Construct the type of primEraseEquality, e.g.
  -- @{a : Level} {A : Set a} {x y : A} → eq {a} {A} x y -> eq {a} {A} x y@.
  t <- let xeqy = pure $ El eqSort $ Def eq $ map Apply $ teleArgs eqTel in
       telePi_ (fmap hide eqTel) <$> (xeqy --> xeqy)

  -- Get the constructor corresponding to BUILTIN REFL
  refl <- getRefl

  -- The implementation of primEraseEquality:
  return $ PrimImpl t $ primFun __IMPOSSIBLE__ (1 + size eqTel) $ \ ts -> do
    let (u, v) = fromMaybe __IMPOSSIBLE__ $ last2 =<< initMaybe ts
    -- Andreas, 2013-07-22.
    -- Note that we cannot call the conversion checker here,
    -- because 'reduce' might be called in a context where
    -- some bound variables do not have a type (just __DUMMY_TYPE__),
    -- and the conversion checker for eliminations does not
    -- like this.
    -- We can only do untyped equality, e.g., by normalisation.
    (u', v') <- normalise' (u, v)
    if u' == v' then redReturn $ refl u else
      return $ NoReduction $ map notReduced ts

-- | Get the 'ArgInfo' of the principal argument of BUILTIN REFL.
--
--   Returns @Nothing@ for e.g.
--   @
--     data Eq {a} {A : Set a} (x : A) : A → Set a where
--       refl : Eq x x
--   @
--
--   Returns @Just ...@ for e.g.
--   @
--     data Eq {a} {A : Set a} : (x y : A) → Set a where
--       refl : ∀ x → Eq x x
--   @

getReflArgInfo :: ConHead -> TCM (Maybe ArgInfo)
getReflArgInfo rf = do
  def <- getConInfo rf
  TelV reflTel _ <- telView $ defType def
  return $ fmap getArgInfo $ listToMaybe $ drop (conPars $ theDef def) $ telToList reflTel


-- | Used for both @primForce@ and @primForceLemma@.
genPrimForce :: TCM Type -> (Term -> Arg Term -> Term) -> TCM PrimitiveImpl
genPrimForce b ret = do
  let varEl s a = El (varSort s) <$> a
      varT s a  = varEl s (varM a)
      varS s    = pure $ sort $ varSort s
  t <- hPi "a" (el primLevel) $
       hPi "b" (el primLevel) $
       hPi "A" (varS 1) $
       hPi "B" (varT 2 0 --> varS 1) b
  return $ PrimImpl t $ primFun __IMPOSSIBLE__ 6 $ \ ts ->
    case ts of
      [a, b, s, t, u, f] -> do
        u <- reduceB' u
        let isWHNF Blocked{} = return False
            isWHNF (NotBlocked _ u) =
              case unArg u of
                Lit{}      -> return True
                Con{}      -> return True
                Lam{}      -> return True
                Pi{}       -> return True
                Sort{}     -> return True  -- sorts and levels are considered whnf
                Level{}    -> return True
                DontCare{} -> return True
                Def q _    -> do
                  def <- theDef <$> getConstInfo q
                  return $ case def of
                    Datatype{} -> True
                    Record{}   -> True
                    _          -> False
                Var{}      -> return False
                MetaV{}    -> __IMPOSSIBLE__
                Dummy s _  -> __IMPOSSIBLE_VERBOSE__ s
        ifM (isWHNF u)
            (redReturn $ ret (unArg f) (ignoreBlocking u))
            (return $ NoReduction $ map notReduced [a, b, s, t] ++ [reduced u, notReduced f])
      _ -> __IMPOSSIBLE__

primForce :: TCM PrimitiveImpl
primForce = do
  let varEl s a = El (varSort s) <$> a
      varT s a  = varEl s (varM a)
  genPrimForce (nPi "x" (varT 3 1) $
                nPi "y" (varT 4 2) (varEl 4 $ varM 2 <@> varM 0) -->
                varEl 3 (varM 1 <@> varM 0)) $
    \ f u -> apply f [u]

primForceLemma :: TCM PrimitiveImpl
primForceLemma = do
  let varEl s a = El (varSort s) <$> a
      varT s a  = varEl s (varM a)
  refl  <- primRefl
  force <- primFunName <$> getPrimitive PrimForce
  genPrimForce (nPi "x" (varT 3 1) $
                nPi "f" (nPi "y" (varT 4 2) $ varEl 4 $ varM 2 <@> varM 0) $
                varEl 4 $ primEquality <#> varM 4 <#> (varM 2 <@> varM 1)
                                       <@> (pure (Def force []) <#> varM 5 <#> varM 4 <#> varM 3 <#> varM 2 <@> varM 1 <@> varM 0)
                                       <@> (varM 0 <@> varM 1)
               ) $ \ _ _ -> refl

mkPrimLevelZero :: TCM PrimitiveImpl
mkPrimLevelZero = do
  t <- primType (undefined :: Lvl)
  return $ PrimImpl t $ primFun __IMPOSSIBLE__ 0 $ \_ -> redReturn $ Level $ ClosedLevel 0

mkPrimLevelSuc :: TCM PrimitiveImpl
mkPrimLevelSuc = do
  t <- primType (id :: Lvl -> Lvl)
  return $ PrimImpl t $ primFun __IMPOSSIBLE__ 1 $ \ ~[a] -> do
    l <- levelView' $ unArg a
    redReturn $ Level $ levelSuc l

mkPrimLevelMax :: TCM PrimitiveImpl
mkPrimLevelMax = do
  t <- primType (max :: Op Lvl)
  return $ PrimImpl t $ primFun __IMPOSSIBLE__ 2 $ \ ~[a, b] -> do
    a' <- levelView' $ unArg a
    b' <- levelView' $ unArg b
    redReturn $ Level $ levelLub a' b'

primLockUniv' :: TCM PrimitiveImpl
primLockUniv' = do
  let t = sort $ Type $ levelSuc $ Max 0 []
  return $ PrimImpl t $ primFun __IMPOSSIBLE__ 0 $ \_ -> redReturn $ Sort LockUniv

mkPrimFun1TCM :: (FromTerm a, ToTerm b) =>
                 TCM Type -> (a -> ReduceM b) -> TCM PrimitiveImpl
mkPrimFun1TCM mt f = do
    toA   <- fromTerm
    fromB <- toTerm
    t     <- mt
    return $ PrimImpl t $ primFun __IMPOSSIBLE__ 1 $ \ts ->
      case ts of
        [v] ->
          redBind (toA v) (pure . singleton) $ \ x -> do
            b <- fromB =<< f x
            case allMetas Set.singleton b of
              ms | Set.null ms -> redReturn b
                 | otherwise   -> return $ NoReduction [reduced (Blocked (unblockOnAllMetas ms) v)]
        _ -> __IMPOSSIBLE__

-- Tying the knot
mkPrimFun1 :: (PrimType a, FromTerm a, PrimType b, ToTerm b) =>
              (a -> b) -> TCM PrimitiveImpl
mkPrimFun1 f = do
    toA   <- fromTerm
    fromB <- toTerm
    t     <- primType f
    return $ PrimImpl t $ primFun __IMPOSSIBLE__ 1 $ \ts ->
      case ts of
        [v] ->
          redBind (toA v) (pure . singleton) $ \ x ->
          redReturn =<< fromB (f x)
        _ -> __IMPOSSIBLE__

mkPrimFun2 :: ( PrimType a, FromTerm a, ToTerm a
              , PrimType b, FromTerm b
              , PrimType c, ToTerm c ) =>
              (a -> b -> c) -> TCM PrimitiveImpl
mkPrimFun2 f = do
    toA   <- fromTerm
    fromA <- toTerm
    toB   <- fromTerm
    fromC <- toTerm
    t     <- primType f
    return $ PrimImpl t $ primFun __IMPOSSIBLE__ 2 $ \ts ->
      case ts of
        [v,w] ->
          redBind (toA v)
              (\v' -> pure [v', notReduced w]) $ \x ->
          redBind (toB w)
              (\w' -> do
                xTm <- fromA x
                pure [reduced $ notBlocked $ Arg (argInfo v) xTm , w']
              ) $ \y ->
          redReturn =<< fromC (f x y)
        _ -> __IMPOSSIBLE__

mkPrimFun3 :: ( PrimType a, FromTerm a, ToTerm a
              , PrimType b, FromTerm b, ToTerm b
              , PrimType c, FromTerm c
              , PrimType d, ToTerm d ) =>
              (a -> b -> c -> d) -> TCM PrimitiveImpl
mkPrimFun3 f = do
    (toA, fromA) <- (,) <$> fromTerm <*> toTerm
    (toB, fromB) <- (,) <$> fromTerm <*> toTerm
    toC          <- fromTerm
    fromD        <- toTerm
    t <- primType f
    return $ PrimImpl t $ primFun __IMPOSSIBLE__ 3 $ \ts ->
      let argFrom fromX a x =
            reduced . notBlocked . Arg (argInfo a) <$> fromX x
      in case ts of
        [a,b,c] ->
          redBind (toA a)
              (\a' -> pure [a', notReduced b, notReduced c]) $ \x ->
          redBind (toB b)
              (\b' -> sequence
                [ argFrom fromA a x
                , pure b'
                , pure $ notReduced c ]) $ \y ->
          redBind (toC c)
              (\c' -> sequence
                [ argFrom fromA a x
                , argFrom fromB b y
                , pure c' ]) $ \z ->
          redReturn =<< fromD (f x y z)
        _ -> __IMPOSSIBLE__

mkPrimFun4 :: ( PrimType a, FromTerm a, ToTerm a
              , PrimType b, FromTerm b, ToTerm b
              , PrimType c, FromTerm c, ToTerm c
              , PrimType d, FromTerm d
              , PrimType e, ToTerm e ) =>
              (a -> b -> c -> d -> e) -> TCM PrimitiveImpl
mkPrimFun4 f = do
    (toA, fromA) <- (,) <$> fromTerm <*> toTerm
    (toB, fromB) <- (,) <$> fromTerm <*> toTerm
    (toC, fromC) <- (,) <$> fromTerm <*> toTerm
    toD          <- fromTerm
    fromE        <- toTerm
    t <- primType f
    return $ PrimImpl t $ primFun __IMPOSSIBLE__ 4 $ \ts ->
      let argFrom fromX a x =
            reduced . notBlocked . Arg (argInfo a) <$> fromX x
      in case ts of
        [a,b,c,d] ->
          redBind (toA a)
              (\a' -> pure $ a' : map notReduced [b, c, d]) $ \x ->
          redBind (toB b)
              (\b' -> sequence
                [ argFrom fromA a x
                , pure b'
                , pure $ notReduced c
                , pure $ notReduced d ]) $ \y ->
          redBind (toC c)
              (\c' -> sequence
                [ argFrom fromA a x
                , argFrom fromB b y
                , pure c'
                , pure $ notReduced d ]) $ \z ->
          redBind (toD d)
              (\d' -> sequence
                [ argFrom fromA a x
                , argFrom fromB b y
                , argFrom fromC c z
                , pure d' ]) $ \w ->

          redReturn =<< fromE (f x y z w)
        _ -> __IMPOSSIBLE__


---------------------------------------------------------------------------
-- * The actual primitive functions
---------------------------------------------------------------------------

type Op   a = a -> a -> a
type Fun  a = a -> a
type Rel  a = a -> a -> Bool
type Pred a = a -> Bool

primitiveFunctions :: Map PrimitiveId (TCM PrimitiveImpl)
primitiveFunctions = localTCStateSavingWarnings <$> Map.fromListWith __IMPOSSIBLE__
  -- Issue #4375          ^^^^^^^^^^^^^^^^^^^^^^^^^^
  --   Without this the next fresh checkpoint id gets changed building the primitive functions. This
  --   is bad for caching since it happens when scope checking import declarations (rebinding
  --   primitives). During type checking, the caching machinery might then load a cached state with
  --   out-of-date checkpoint ids. Make sure to preserve warnings though, since they include things
  --   like using unsafe things primitives with `--safe`.

  -- Ulf, 2015-10-28: Builtin integers now map to a datatype, and since you
  -- can define these functions (reasonably) efficiently using the primitive
  -- functions on natural numbers there's no need for them anymore. Keeping the
  -- show function around for convenience, and as a test case for a primitive
  -- function taking an integer.
  -- -- Integer functions
  -- [ "primIntegerPlus"     |-> mkPrimFun2 ((+)        :: Op Integer)
  -- , "primIntegerMinus"    |-> mkPrimFun2 ((-)        :: Op Integer)
  -- , "primIntegerTimes"    |-> mkPrimFun2 ((*)        :: Op Integer)
  -- , "primIntegerDiv"      |-> mkPrimFun2 (div        :: Op Integer)    -- partial
  -- , "primIntegerMod"      |-> mkPrimFun2 (mod        :: Op Integer)    -- partial
  -- , "primIntegerEquality" |-> mkPrimFun2 ((==)       :: Rel Integer)
  -- , "primIntegerLess"     |-> mkPrimFun2 ((<)        :: Rel Integer)
  -- , "primIntegerAbs"      |-> mkPrimFun1 (Nat . abs  :: Integer -> Nat)
  -- , "primNatToInteger"    |-> mkPrimFun1 (toInteger  :: Nat -> Integer)
  [ PrimShowInteger     |-> mkPrimFun1 (T.pack . prettyShow :: Integer -> Text)

  -- Natural number functions
  , PrimNatPlus           |-> mkPrimFun2 ((+)                     :: Op Nat)
  , PrimNatMinus          |-> mkPrimFun2 ((\x y -> max 0 (x - y)) :: Op Nat)
  , PrimNatTimes          |-> mkPrimFun2 ((*)                     :: Op Nat)
  , PrimNatDivSucAux      |-> mkPrimFun4 ((\k m n j -> k + div (max 0 $ n + m - j) (m + 1)) :: Nat -> Nat -> Op Nat)
  , PrimNatModSucAux      |->
      let aux :: Nat -> Nat -> Op Nat
          aux k m n j | n > j     = mod (n - j - 1) (m + 1)
                      | otherwise = k + n
      in mkPrimFun4 aux
  , PrimNatEquality       |-> mkPrimFun2 ((==) :: Rel Nat)
  , PrimNatLess           |-> mkPrimFun2 ((<)  :: Rel Nat)
  , PrimShowNat           |-> mkPrimFun1 (T.pack . prettyShow :: Nat -> Text)

  -- -- Machine words
  , PrimWord64ToNat      |-> mkPrimFun1 (fromIntegral :: Word64 -> Nat)
  , PrimWord64FromNat    |-> mkPrimFun1 (fromIntegral :: Nat -> Word64)
  , PrimWord64ToNatInjective |-> primWord64ToNatInjective

  -- -- Level functions
  , PrimLevelZero         |-> mkPrimLevelZero
  , PrimLevelSuc          |-> mkPrimLevelSuc
  , PrimLevelMax          |-> mkPrimLevelMax

  -- Floating point functions
  --
  -- Wen, 2020-08-26: Primitives which convert from Float into other, more
  -- well-behaved numeric types should check for unrepresentable values, e.g.,
  -- NaN and the infinities, and return `nothing` if those are encountered, to
  -- ensure that the returned numbers are sensible. That means `primFloatRound`,
  -- `primFloatFloor`, `primFloatCeiling`, and `primFloatDecode`. The conversion
  -- `primFloatRatio` represents NaN as (0,0), and the infinities as (±1,0).
  --
  , PrimFloatEquality            |-> mkPrimFun2 doubleEq
  , PrimFloatInequality          |-> mkPrimFun2 doubleLe
  , PrimFloatLess                |-> mkPrimFun2 doubleLt
  , PrimFloatIsInfinite          |-> mkPrimFun1 (isInfinite :: Double -> Bool)
  , PrimFloatIsNaN               |-> mkPrimFun1 (isNaN :: Double -> Bool)
  , PrimFloatIsNegativeZero      |-> mkPrimFun1 (isNegativeZero :: Double -> Bool)
  , PrimFloatIsSafeInteger       |-> mkPrimFun1 isSafeInteger
  , PrimFloatToWord64            |-> mkPrimFun1 doubleToWord64
  , PrimFloatToWord64Injective   |-> primFloatToWord64Injective
  , PrimNatToFloat               |-> mkPrimFun1 (intToDouble :: Nat -> Double)
  , PrimIntToFloat               |-> mkPrimFun1 (intToDouble :: Integer -> Double)
  , PrimFloatRound               |-> mkPrimFun1 doubleRound
  , PrimFloatFloor               |-> mkPrimFun1 doubleFloor
  , PrimFloatCeiling             |-> mkPrimFun1 doubleCeiling
  , PrimFloatToRatio             |-> mkPrimFun1 doubleToRatio
  , PrimRatioToFloat             |-> mkPrimFun2 ratioToDouble
  , PrimFloatDecode              |-> mkPrimFun1 doubleDecode
  , PrimFloatEncode              |-> mkPrimFun2 doubleEncode
  , PrimShowFloat                |-> mkPrimFun1 (T.pack . show :: Double -> Text)
  , PrimFloatPlus                |-> mkPrimFun2 doublePlus
  , PrimFloatMinus               |-> mkPrimFun2 doubleMinus
  , PrimFloatTimes               |-> mkPrimFun2 doubleTimes
  , PrimFloatNegate              |-> mkPrimFun1 doubleNegate
  , PrimFloatDiv                 |-> mkPrimFun2 doubleDiv
  , PrimFloatPow                 |-> mkPrimFun2 doublePow
  , PrimFloatSqrt                |-> mkPrimFun1 doubleSqrt
  , PrimFloatExp                 |-> mkPrimFun1 doubleExp
  , PrimFloatLog                 |-> mkPrimFun1 doubleLog
  , PrimFloatSin                 |-> mkPrimFun1 doubleSin
  , PrimFloatCos                 |-> mkPrimFun1 doubleCos
  , PrimFloatTan                 |-> mkPrimFun1 doubleTan
  , PrimFloatASin                |-> mkPrimFun1 doubleASin
  , PrimFloatACos                |-> mkPrimFun1 doubleACos
  , PrimFloatATan                |-> mkPrimFun1 doubleATan
  , PrimFloatATan2               |-> mkPrimFun2 doubleATan2
  , PrimFloatSinh                |-> mkPrimFun1 doubleSinh
  , PrimFloatCosh                |-> mkPrimFun1 doubleCosh
  , PrimFloatTanh                |-> mkPrimFun1 doubleTanh
  , PrimFloatASinh               |-> mkPrimFun1 doubleASinh
  , PrimFloatACosh               |-> mkPrimFun1 doubleCosh
  , PrimFloatATanh               |-> mkPrimFun1 doubleTanh

  -- Character functions
  , PrimCharEquality         |-> mkPrimFun2 ((==) :: Rel Char)
  , PrimIsLower              |-> mkPrimFun1 isLower
  , PrimIsDigit              |-> mkPrimFun1 isDigit
  , PrimIsAlpha              |-> mkPrimFun1 isAlpha
  , PrimIsSpace              |-> mkPrimFun1 isSpace
  , PrimIsAscii              |-> mkPrimFun1 isAscii
  , PrimIsLatin1             |-> mkPrimFun1 isLatin1
  , PrimIsPrint              |-> mkPrimFun1 isPrint
  , PrimIsHexDigit           |-> mkPrimFun1 isHexDigit
  , PrimToUpper              |-> mkPrimFun1 toUpper
  , PrimToLower              |-> mkPrimFun1 toLower
  , PrimCharToNat            |-> mkPrimFun1 (fromIntegral . fromEnum :: Char -> Nat)
  , PrimCharToNatInjective   |-> primCharToNatInjective
  , PrimNatToChar            |-> mkPrimFun1 (integerToChar . unNat)
  , PrimShowChar             |-> mkPrimFun1 (T.pack . prettyShow . LitChar)

  -- String functions
  , PrimStringToList              |-> mkPrimFun1 T.unpack
  , PrimStringToListInjective     |-> primStringToListInjective
  , PrimStringFromList            |-> mkPrimFun1 T.pack
  , PrimStringFromListInjective   |-> primStringFromListInjective
  , PrimStringAppend              |-> mkPrimFun2 (T.append :: Text -> Text -> Text)
  , PrimStringEquality            |-> mkPrimFun2 ((==) :: Rel Text)
  , PrimShowString                |-> mkPrimFun1 (T.pack . prettyShow . LitString)
  , PrimStringUncons              |-> mkPrimFun1 T.uncons

  -- Other stuff
  , PrimEraseEquality     |-> primEraseEquality
    -- This needs to be force : A → ((x : A) → B x) → B x rather than seq because of call-by-name.
  , PrimForce             |-> primForce
  , PrimForceLemma        |-> primForceLemma
  , PrimQNameEquality     |-> mkPrimFun2 ((==) :: Rel QName)
  , PrimQNameLess         |-> mkPrimFun2 ((<) :: Rel QName)
  , PrimShowQName         |-> mkPrimFun1 (T.pack . prettyShow :: QName -> Text)
  , PrimQNameFixity       |-> mkPrimFun1 (nameFixity . qnameName)
  , PrimQNameToWord64s    |-> mkPrimFun1 ((\ (NameId x (ModuleNameHash y)) -> (x, y)) . nameId . qnameName
                                          :: QName -> (Word64, Word64))
  , PrimQNameToWord64sInjective   |-> primQNameToWord64sInjective
  , PrimMetaEquality      |-> mkPrimFun2 ((==) :: Rel MetaId)
  , PrimMetaLess          |-> mkPrimFun2 ((<) :: Rel MetaId)
  , PrimShowMeta          |-> mkPrimFun1 (T.pack . prettyShow :: MetaId -> Text)
  , PrimMetaToNat         |-> mkPrimFun1 metaToNat
  , PrimMetaToNatInjective   |-> primMetaToNatInjective

  , PrimIMin              |-> primIMin'
  , PrimIMax              |-> primIMax'
  , PrimINeg              |-> primINeg'
  , PrimPOr               |-> primPOr
  , PrimComp              |-> primComp
  , PrimTrans             |-> primTrans'
  , PrimHComp             |-> primHComp'
  , PrimPartial           |-> primPartial'
  , PrimPartialP          |-> primPartialP'
  , PrimGlue              |-> primGlue'
  , Prim_glue             |-> prim_glue'
  , Prim_unglue           |-> prim_unglue'
  , PrimFaceForall        |-> primFaceForall'
  , PrimSubOut            |-> primSubOut'
  , Prim_glueU            |-> prim_glueU'
  , Prim_unglueU          |-> prim_unglueU'
  , PrimLockUniv          |-> primLockUniv'
  ]
  where
    (|->) = (,)
