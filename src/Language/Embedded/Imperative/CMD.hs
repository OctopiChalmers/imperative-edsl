{-# LANGUAGE CPP #-}

-- | Imperative commands. These commands can be used with the 'Program' monad,
-- and different command types can be combined using (':+:').
--
-- These commands are general imperative constructs independent of the back end,
-- except for 'CallCMD' which is C-specific.

module Language.Embedded.Imperative.CMD
  ( -- * References
    Ref (..)
  , RefCMD (..)
    -- * Arrays
  , Arr (..)
  , ArrCMD (..)
    -- * Control flow
  , Border (..)
  , borderVal
  , borderIncl
  , IxRange
  , ControlCMD (..)
    -- * File handling
  , Handle (..)
  , stdin
  , stdout
  , Formattable (..)
  , FileCMD (..)
  , PrintfArg (..)
    -- * Abstract objects
  , Object (..)
  , ObjectCMD (..)
    -- * External function calls (C-specific)
  , FunArg (..)
  , VarPredCast
  , Arg (..)
  , CallCMD (..)
  ) where



import Data.Array.IO
import Data.Char (isSpace)
import Data.Int
import Data.IORef
import Data.List
import Data.Typeable
import Data.Word
import System.IO (IOMode (..))
import qualified System.IO as IO
import qualified Text.Printf as Printf

#if __GLASGOW_HASKELL__ < 710
import Data.Foldable hiding (sequence_)
import Data.Traversable
#endif

#if __GLASGOW_HASKELL__ < 708
import Data.Proxy
#endif

import Control.Monad.Operational.Higher

import Control.Monads
import Language.Embedded.Expression
import Language.Embedded.Traversal
import qualified Language.C.Syntax as C
import Language.C.Quote.C (ToIdent (..))
import Language.C.Monad


--------------------------------------------------------------------------------
-- * References
--------------------------------------------------------------------------------

-- | Mutable reference
data Ref a
    = RefComp VarId
    | RefEval (IORef a)
  deriving Typeable

-- | Identifiers from references
instance ToIdent (Ref a)
  where
    toIdent (RefComp r) = C.Id ('v' : show r)

-- | Commands for mutable references
data RefCMD exp (prog :: * -> *) a
  where
    NewRef  :: VarPred exp a => RefCMD exp prog (Ref a)
    InitRef :: VarPred exp a => exp a -> RefCMD exp prog (Ref a)
    GetRef  :: VarPred exp a => Ref a -> RefCMD exp prog (exp a)
    SetRef  :: VarPred exp a => Ref a -> exp a -> RefCMD exp prog ()
      -- `VarPred` for `SetRef` is not needed for code generation, but it can be useful when
      -- interpreting with a dynamically typed store. `VarPred` can then be used to supply a
      -- `Typeable` dictionary for casting.
    UnsafeFreezeRef :: VarPred exp a => Ref a -> RefCMD exp prog (exp a)
      -- Like `GetRef` but without using a fresh variable for the result. This
      -- is only safe if the reference is never written to after the freezing.
#if  __GLASGOW_HASKELL__>=708
  deriving Typeable
#endif

instance HFunctor (RefCMD exp)
  where
    hfmap _ NewRef       = NewRef
    hfmap _ (InitRef a)  = InitRef a
    hfmap _ (GetRef r)   = GetRef r
    hfmap _ (SetRef r a) = SetRef r a
    hfmap _ (UnsafeFreezeRef r) = UnsafeFreezeRef r

instance CompExp exp => DryInterp (RefCMD exp)
  where
    dryInterp NewRef       = liftM RefComp fresh
    dryInterp (InitRef _)  = liftM RefComp fresh
    dryInterp (GetRef _)   = liftM varExp fresh
    dryInterp (SetRef _ _) = return ()
    dryInterp (UnsafeFreezeRef (RefComp v)) = return $ varExp v

type instance IExp (RefCMD e)       = e
type instance IExp (RefCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Arrays
--------------------------------------------------------------------------------

-- | Mutable array
data Arr i a
    = ArrComp String
    | ArrEval (IOArray i a)
  deriving Typeable

-- In a way, it's not terribly useful to have `Arr` parameterized on the index
-- type, since it's required to be an integer type, and it doesn't really matter
-- which integer type is used since we can always cast between them.
--
-- Another option would be to remove the parameter and allow any integer type
-- when indexing (and use e.g. `IOArray Word32` for evaluation). However this
-- has the big downside of losing type inference. E.g. the statement
-- `getArr arr 0` would be ambiguously typed.
--
-- Yet another option is to hard-code a specific index type. But this would
-- limit the use of arrays to specific platforms.
--
-- So in the end, the above representation seems like a good trade-off. A client
-- of `imperative-edsl` may always chose to make a wrapper interface that uses
-- a specific index type.

-- | Identifiers from arrays
instance ToIdent (Arr i a)
  where
    toIdent (ArrComp arr) = C.Id arr

-- | Commands for mutable arrays
data ArrCMD exp (prog :: * -> *) a
  where
    NewArr  :: (VarPred exp a, VarPred exp i, Integral i, Ix i) => exp i -> ArrCMD exp prog (Arr i a)
    NewArr_ :: (VarPred exp a, VarPred exp i, Integral i, Ix i) => ArrCMD exp prog (Arr i a)
    InitArr :: (VarPred exp a, VarPred exp i, Integral i, Ix i) => [a] -> ArrCMD exp prog (Arr i a)
    GetArr  :: (VarPred exp a, VarPred exp i, Integral i, Ix i) => exp i -> Arr i a -> ArrCMD exp prog (exp a)
    SetArr  :: (VarPred exp a, VarPred exp i, Integral i, Ix i) => exp i -> exp a -> Arr i a -> ArrCMD exp prog ()
    CopyArr :: (VarPred exp a, VarPred exp i, Integral i, Ix i) => Arr i a -> Arr i a -> exp i -> ArrCMD exp prog ()
#if  __GLASGOW_HASKELL__>=708
  deriving Typeable
#endif
  -- Not all `VarPred` constraints are needed by the back ends in
  -- imperative-edsl, but they may still be useful for other back ends.

instance HFunctor (ArrCMD exp)
  where
    hfmap _ (NewArr n)        = NewArr n
    hfmap _ (NewArr_)         = NewArr_
    hfmap _ (InitArr as)      = InitArr as
    hfmap _ (GetArr i arr)    = GetArr i arr
    hfmap _ (SetArr i a arr)  = SetArr i a arr
    hfmap _ (CopyArr a1 a2 l) = CopyArr a1 a2 l

instance CompExp exp => DryInterp (ArrCMD exp)
  where
    dryInterp (NewArr _)      = liftM ArrComp $ freshStr "a"
    dryInterp (NewArr_)       = liftM ArrComp $ freshStr "a"
    dryInterp (InitArr _)     = liftM ArrComp $ freshStr "a"
    dryInterp (GetArr _ _)    = liftM varExp fresh
    dryInterp (SetArr _ _ _)  = return ()
    dryInterp (CopyArr _ _ _) = return ()

type instance IExp (ArrCMD e)       = e
type instance IExp (ArrCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Control flow
--------------------------------------------------------------------------------

data Border i = Incl i | Excl i
  deriving (Eq, Show, Functor, Foldable, Traversable)

-- | 'fromInteger' gives an inclusive border. No other methods defined.
instance Num i => Num (Border i)
  where
    fromInteger = Incl . fromInteger
    (+) = error "(+) not defined for Border"
    (-) = error "(-) not defined for Border"
    (*) = error "(*) not defined for Border"
    abs    = error "abs not defined for Border"
    signum = error "signum not defined for Border"

borderVal :: Border i -> i
borderVal (Incl i) = i
borderVal (Excl i) = i

borderIncl :: Border i -> Bool
borderIncl (Incl _) = True
borderIncl _        = False

-- | Index range
--
-- @(lo,step,hi)@
--
-- @lo@ gives the start index; @step@ gives the step length; @hi@ gives the stop
-- index which may be inclusive or exclusive.
type IxRange i = (i, Int, Border i)

data ControlCMD exp prog a
  where
    If     :: exp Bool -> prog () -> prog () -> ControlCMD exp prog ()
    While  :: prog (exp Bool) -> prog () -> ControlCMD exp prog ()
    For    :: (VarPred exp n, Integral n) =>
              IxRange (exp n) -> (exp n -> prog ()) -> ControlCMD exp prog ()
    Break  :: ControlCMD exp prog ()
    Assert :: exp Bool -> String -> ControlCMD exp prog ()

instance HFunctor (ControlCMD exp)
  where
    hfmap g (If c t f)        = If c (g t) (g f)
    hfmap g (While cont body) = While (g cont) (g body)
    hfmap g (For ir body)     = For ir (g . body)
    hfmap _ Break             = Break
    hfmap _ (Assert cond msg) = Assert cond msg

instance DryInterp (ControlCMD exp)
  where
    dryInterp (If _ _ _)   = return ()
    dryInterp (While _ _)  = return ()
    dryInterp (For _ _)    = return ()
    dryInterp Break        = return ()
    dryInterp (Assert _ _) = return ()

type instance IExp (ControlCMD e)       = e
type instance IExp (ControlCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * File handling
--------------------------------------------------------------------------------

-- | File handle
data Handle
    = HandleComp String
    | HandleEval IO.Handle
  deriving Typeable

-- | Identifiers from handles
instance ToIdent Handle
  where
    toIdent (HandleComp h) = C.Id h

-- | Handle to stdin
stdin :: Handle
stdin = HandleComp "stdin"

-- | Handle to stdout
stdout :: Handle
stdout = HandleComp "stdout"

-- | Values that can be printed\/scanned using @printf@\/@scanf@
class (Typeable a, Read a, Printf.PrintfArg a) => Formattable a
  where
    formatSpecifier :: Proxy a -> String

instance Formattable Int    where formatSpecifier _ = "%d"
instance Formattable Int8   where formatSpecifier _ = "%d"
instance Formattable Int16  where formatSpecifier _ = "%d"
instance Formattable Int32  where formatSpecifier _ = "%d"
instance Formattable Int64  where formatSpecifier _ = "%d"
instance Formattable Word   where formatSpecifier _ = "%u"
instance Formattable Word8  where formatSpecifier _ = "%u"
instance Formattable Word16 where formatSpecifier _ = "%u"
instance Formattable Word32 where formatSpecifier _ = "%u"
instance Formattable Word64 where formatSpecifier _ = "%u"
instance Formattable Float  where formatSpecifier _ = "%f"
instance Formattable Double where formatSpecifier _ = "%f"

data FileCMD exp (prog :: * -> *) a
  where
    FOpen   :: FilePath -> IOMode                       -> FileCMD exp prog Handle
    FClose  :: Handle                                   -> FileCMD exp prog ()
    FEof    :: VarPred exp Bool => Handle               -> FileCMD exp prog (exp Bool)
    FPrintf :: Handle -> String -> [PrintfArg exp]      -> FileCMD exp prog ()
    FGet    :: (Formattable a, VarPred exp a) => Handle -> FileCMD exp prog (exp a)

data PrintfArg exp where
  PrintfArg :: (Printf.PrintfArg a, VarPred exp a) => exp a -> PrintfArg exp

instance HFunctor (FileCMD exp)
  where
    hfmap _ (FOpen file mode)     = FOpen file mode
    hfmap _ (FClose hdl)          = FClose hdl
    hfmap _ (FPrintf hdl form as) = FPrintf hdl form as
    hfmap _ (FGet hdl)            = FGet hdl
    hfmap _ (FEof hdl)            = FEof hdl

instance CompExp exp => DryInterp (FileCMD exp)
  where
    dryInterp (FOpen _ _)     = liftM HandleComp $ freshStr "h"
    dryInterp (FClose _)      = return ()
    dryInterp (FPrintf _ _ _) = return ()
    dryInterp (FGet _)        = liftM varExp fresh
    dryInterp (FEof _)        = liftM varExp fresh

type instance IExp (FileCMD e)       = e
type instance IExp (FileCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Abstract objects
--------------------------------------------------------------------------------

data Object = Object
    { pointed    :: Bool
    , objectType :: String
    , objectId   :: String
    }
  deriving (Eq, Show, Ord, Typeable)

-- | Identifiers from objects
instance ToIdent Object
  where
    toIdent (Object _ _ o) = C.Id o

data ObjectCMD exp (prog :: * -> *) a
  where
    NewObject
        :: String  -- Type
        -> ObjectCMD exp prog Object
    InitObject
        :: String -- Function name
        -> Bool   -- Pointed object?
        -> String -- Object Type
        -> [FunArg exp]
        -> ObjectCMD exp prog Object

instance HFunctor (ObjectCMD exp)
  where
    hfmap _ (NewObject t)        = NewObject t
    hfmap _ (InitObject s p t a) = InitObject s p t a

instance DryInterp (ObjectCMD exp)
  where
    dryInterp (NewObject t)        = liftM (Object True t) $ freshStr "obj"
    dryInterp (InitObject _ _ t _) = liftM (Object True t) $ freshStr "obj"

type instance IExp (ObjectCMD e)       = e
type instance IExp (ObjectCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * External function calls (C-specific)
--------------------------------------------------------------------------------

data FunArg exp where
  FunArg :: Arg arg => arg exp -> FunArg exp

-- | Evidence that @`VarPred` exp1@ implies @`VarPred` exp2@
type VarPredCast exp1 exp2 = forall a b .
    VarPred exp1 a => Proxy a -> (VarPred exp2 a => b) -> b

class Arg arg where
  mkArg   :: CompExp exp => arg exp -> CGen C.Exp
  mkParam :: CompExp exp => arg exp -> CGen C.Param

  -- | Map over the expression(s) in an argument
  mapArg  :: VarPredCast exp1 exp2
          -> (forall a . VarPred exp1 a => exp1 a -> exp2 a)
          -> arg exp1
          -> arg exp2

  -- | Monadic map over the expression(s) in an argument
  mapMArg :: Monad m
          => VarPredCast exp1 exp2
          -> (forall a . VarPred exp1 a => exp1 a -> m (exp2 a))
          -> arg exp1
          -> m (arg exp2)

instance Arg FunArg where
  mkArg   (FunArg arg) = mkArg arg
  mkParam (FunArg arg) = mkParam arg
  mapArg  predCast f (FunArg arg) = FunArg (mapArg predCast f arg)
  mapMArg predCast f (FunArg arg) = liftM FunArg (mapMArg predCast f arg)

data CallCMD exp (prog :: * -> *) a
  where
    AddInclude    :: String       -> CallCMD exp prog ()
    AddDefinition :: C.Definition -> CallCMD exp prog ()
    AddExternFun  :: VarPred exp res
                  => String
                  -> proxy (exp res)
                  -> [FunArg exp]
                  -> CallCMD exp prog ()
    AddExternProc :: String -> [FunArg exp] -> CallCMD exp prog ()
    CallFun       :: VarPred exp a => String -> [FunArg exp] -> CallCMD exp prog (exp a)
    CallProc      ::                  String -> [FunArg exp] -> CallCMD exp prog ()

instance HFunctor (CallCMD exp)
  where
    hfmap _ (AddInclude incl)           = AddInclude incl
    hfmap _ (AddDefinition def)         = AddDefinition def
    hfmap _ (AddExternFun fun res args) = AddExternFun fun res args
    hfmap _ (AddExternProc proc args)   = AddExternProc proc args
    hfmap _ (CallFun fun args)          = CallFun fun args
    hfmap _ (CallProc proc args)        = CallProc proc args

instance CompExp exp => DryInterp (CallCMD exp)
  where
    dryInterp (AddInclude _)       = return ()
    dryInterp (AddDefinition _)    = return ()
    dryInterp (AddExternFun _ _ _) = return ()
    dryInterp (AddExternProc _ _)  = return ()
    dryInterp (CallFun _ _)        = liftM varExp fresh
    dryInterp (CallProc _ _)       = return ()

type instance IExp (CallCMD e)       = e
type instance IExp (CallCMD e :+: i) = e



--------------------------------------------------------------------------------
-- * Running commands
--------------------------------------------------------------------------------

runRefCMD :: forall exp prog a . EvalExp exp => RefCMD exp prog a -> IO a
runRefCMD (InitRef a)                       = fmap RefEval $ newIORef $ evalExp a
runRefCMD NewRef                            = fmap RefEval $ newIORef $ error "reading uninitialized reference"
runRefCMD (SetRef (RefEval r) a)            = writeIORef r $ evalExp a
runRefCMD (GetRef (RefEval (r :: IORef b))) = fmap litExp $ readIORef r
runRefCMD (UnsafeFreezeRef r)               = runRefCMD (GetRef r)

runArrCMD :: EvalExp exp => ArrCMD exp prog a -> IO a
runArrCMD (NewArr n)   = fmap ArrEval $ newArray_ (0, fromIntegral (evalExp n)-1)
runArrCMD (NewArr_)    = error "NewArr_ not allowed in interpreted mode"
runArrCMD (InitArr as) = fmap ArrEval $ newListArray (0, genericLength as - 1) as
runArrCMD (GetArr i (ArrEval arr)) =
    fmap litExp $ readArray arr (fromIntegral (evalExp i))
runArrCMD (SetArr i a (ArrEval arr)) =
    writeArray arr (fromIntegral (evalExp i)) (evalExp a)
runArrCMD (CopyArr (ArrEval arr1) (ArrEval arr2) l) = sequence_
    [ readArray arr2 i >>= writeArray arr1 i
      | i <- genericTake (evalExp l) [0..]
    ]

runControlCMD :: EvalExp exp => ControlCMD exp IO a -> IO a
runControlCMD (If c t f)        = if evalExp c then t else f
runControlCMD (While cont body) = loop
  where loop = do
          c <- cont
          when (evalExp c) $ body >> loop
runControlCMD (For (lo,step,hi) body) = loop (evalExp lo)
  where
    incl = borderIncl hi
    hi'  = evalExp $ borderVal hi
    cont i
      | incl && (step>=0) = i <= hi'
      | incl && (step<0)  = i >= hi'
      | step >= 0         = i <  hi'
      | step < 0          = i >  hi'
    loop i
      | cont i    = body (litExp i) >> loop (i + fromIntegral step)
      | otherwise = return ()
runControlCMD Break = error "cannot run programs involving break"
runControlCMD (Assert cond msg) = unless (evalExp cond) $ error $
    "Assertion failed: " ++ msg

evalHandle :: Handle -> IO.Handle
evalHandle (HandleEval h)        = h
evalHandle (HandleComp "stdin")  = IO.stdin
evalHandle (HandleComp "stdout") = IO.stdout

readWord :: IO.Handle -> IO String
readWord h = do
    eof <- IO.hIsEOF h
    if eof
    then return ""
    else do
      c  <- IO.hGetChar h
      if isSpace c
      then return ""
      else do
        cs <- readWord h
        return (c:cs)

evalFPrintf :: EvalExp exp =>
    [PrintfArg exp] -> (forall r . Printf.HPrintfType r => r) -> IO ()
evalFPrintf []            pf = pf
evalFPrintf (PrintfArg a:as) pf = evalFPrintf as (pf $ evalExp a)

runFileCMD :: EvalExp exp => FileCMD exp IO a -> IO a
runFileCMD (FOpen file mode)              = fmap HandleEval $ IO.openFile file mode
runFileCMD (FClose (HandleEval h))        = IO.hClose h
runFileCMD (FClose (HandleComp "stdin"))  = return ()
runFileCMD (FClose (HandleComp "stdout")) = return ()
runFileCMD (FPrintf h format as)          = evalFPrintf as (Printf.hPrintf (evalHandle h) format)
runFileCMD (FGet h)   = do
    w <- readWord $ evalHandle h
    case reads w of
        [(f,"")] -> return $ litExp f
        _        -> error $ "fget: no parse (input " ++ show w ++ ")"
runFileCMD (FEof h) = fmap litExp $ IO.hIsEOF $ evalHandle h

runObjectCMD :: ObjectCMD exp IO a -> IO a
runObjectCMD (NewObject _) = error "cannot run programs involving newObject"
runObjectCMD (InitObject _ _ _ _) = error "cannot run programs involving initObject"

runCallCMD :: EvalExp exp => CallCMD exp IO a -> IO a
runCallCMD (AddInclude _)       = return ()
runCallCMD (AddDefinition _)    = return ()
runCallCMD (AddExternFun _ _ _) = return ()
runCallCMD (AddExternProc _ _)  = return ()
runCallCMD (CallFun _ _)        = error "cannot run programs involving callFun"
runCallCMD (CallProc _ _)       = error "cannot run programs involving callProc"

instance EvalExp exp => Interp (RefCMD exp)     IO where interp = runRefCMD
instance EvalExp exp => Interp (ArrCMD exp)     IO where interp = runArrCMD
instance EvalExp exp => Interp (ControlCMD exp) IO where interp = runControlCMD
instance EvalExp exp => Interp (FileCMD exp)    IO where interp = runFileCMD
instance                Interp (ObjectCMD exp)  IO where interp = runObjectCMD
instance EvalExp exp => Interp (CallCMD exp)    IO where interp = runCallCMD

