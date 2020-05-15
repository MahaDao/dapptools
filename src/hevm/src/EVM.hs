{-# Language ImplicitParams #-}
{-# Language ConstraintKinds #-}
{-# Language FlexibleInstances #-}
{-# Language DataKinds #-}
{-# Language GADTs #-}
{-# Language RecordWildCards #-}
{-# Language ScopedTypeVariables #-}
{-# Language StandaloneDeriving #-}
{-# Language StrictData #-}
{-# Language TemplateHaskell #-}
{-# Language TypeOperators #-}
{-# Language ViewPatterns #-}

module EVM where

import Prelude hiding (log, Word, exponent)

import Data.SBV hiding (Word, output, Unknown)
import Data.Proxy (Proxy(..))
import EVM.ABI
import EVM.Types
import EVM.Solidity
import EVM.Keccak
import EVM.Concrete hiding ((^))
import EVM.Op
import EVM.FeeSchedule (FeeSchedule (..))
import qualified EVM.Precompiled

import Data.Binary.Get (runGetOrFail)
import Data.Bits (bit, testBit, complement)
import Data.Bits (xor, shiftR, (.&.), (.|.), FiniteBits (..))
import Data.Text (Text)
import Data.Word (Word8, Word32)
import Control.Lens hiding (op, (:<), (|>), (.>))
import Control.Monad.State.Strict hiding (state)

import Data.ByteString              (ByteString)
import Data.ByteString.Lazy         (fromStrict)
import Data.Map.Strict              (Map)
import Data.Maybe                   (fromMaybe, fromJust)
import Data.Semigroup               (Semigroup (..))
import Data.Sequence                (Seq)
import Data.Vector.Storable         (Vector)
import Data.Foldable                (toList)

import Data.Tree
import Numeric (readHex, showHex)

import qualified Data.ByteString      as BS
import qualified Data.ByteString.Lazy as LS
import qualified Data.ByteString.Char8 as Char8
import qualified Data.ByteArray       as BA
import qualified Data.Map.Strict      as Map
import qualified Data.Sequence        as Seq
import qualified Data.Tree.Zipper     as Zipper
import qualified Data.Vector.Storable as Vector
import qualified Data.Vector.Storable.Mutable as Vector

import qualified Data.Vector as RegularVector

import Crypto.Number.ModArithmetic (expFast)
import Crypto.Hash (Digest, SHA256, RIPEMD160)
import qualified Crypto.Hash as Crypto

-- * Data types

data Error
  = BalanceTooLow Word Word
  | UnrecognizedOpcode Word8
  | SelfDestruction
  | StackUnderrun
  | BadJumpDestination
  | Revert ByteString
  | NoSuchContract Addr
  | OutOfGas Word Word
  | BadCheatCode Word32
  | StackLimitExceeded
  | IllegalOverflow
  | Query Query
  | StateChangeWhileStatic
  | InvalidMemoryAccess
  | CallDepthLimitReached
  | MaxCodeSizeExceeded Word Word
  | PrecompileFailure
  | UnexpectedSymbolicArg
  
deriving instance Show Error

-- | The possible result states of a VM
data VMResult
  = VMFailure Error -- ^ An operation failed
  | VMSuccess [SWord 8] -- ^ Reached STOP, RETURN, or end-of-code
  
deriving instance Show VMResult

-- | The state of a stepwise EVM execution
data VM = VM
  { _result         :: Maybe VMResult
  , _state          :: FrameState
  , _frames         :: [Frame]
  , _env            :: Env
  , _block          :: Block
  , _tx             :: TxState
  , _logs           :: Seq Log
  , _traces         :: Zipper.TreePos Zipper.Empty Trace
  , _cache          :: Cache
  , _execMode       :: ExecMode
  , _burned         :: Word
  , _pathConditions :: [(SBool, Bool)]
  }

data Trace = Trace
  { _traceCodehash :: W256
  , _traceOpIx     :: Int
  , _traceData     :: TraceData
  }

data TraceData
  = EventTrace Log
  | FrameTrace FrameContext
  | QueryTrace Query
  | ErrorTrace Error
  | EntryTrace Text
  | ReturnTrace [SWord 8] FrameContext

data ExecMode = ExecuteNormally | ExecuteAsBlockchainTest | ExecuteAsVMTest

data Query where
  PleaseFetchContract :: Addr         -> (Contract   -> EVM ()) -> Query
  PleaseFetchSlot     :: Addr -> Word -> (Word       -> EVM ()) -> Query
  PleaseAskSMT        :: SymWord -> [SBool] -> (JumpCondition -> EVM ()) -> Query
  PleaseChoosePath    :: (Word -> EVM ()) -> Query

instance Show Query where
  showsPrec _ = \case
    PleaseFetchContract addr _ ->
      (("<EVM.Query: fetch contract " ++ show addr ++ ">") ++)
    PleaseFetchSlot addr slot _ ->
      (("<EVM.Query: fetch slot "
        ++ show slot ++ " for "
        ++ show addr ++ ">") ++)
    PleaseAskSMT condition pathConditions _ ->
      (("<EVM.Query: ask SMT about "
        ++ show condition ++ " in context "
        ++ show pathConditions ++ ">") ++)
    PleaseChoosePath _ ->
      (("<EVM.Query: waiting for user to select path (0,1)") ++)

-- | Alias for the type of e.g. @exec1@.
type EVM a = State VM a

type CodeLocation = (Addr, Word)
data JumpCondition = Known Word | Unknown
  deriving (Show)

-- | The cache is data that can be persisted for efficiency:
-- any expensive query that is constant at least within a block.
data Cache = Cache
  { _fetched :: Map Addr Contract,
    _smtquery :: Map CodeLocation JumpCondition
  } deriving Show

-- | A way to specify an initial VM state
data VMOpts = VMOpts
  { vmoptContract :: Contract
  , vmoptCalldata :: [SWord 8]
  , vmoptValue :: W256
  , vmoptAddress :: Addr
  , vmoptCaller :: Addr
  , vmoptOrigin :: Addr
  , vmoptGas :: W256
  , vmoptGaslimit :: W256
  , vmoptNumber :: W256
  , vmoptTimestamp :: W256
  , vmoptCoinbase :: Addr
  , vmoptDifficulty :: W256
  , vmoptMaxCodeSize :: W256
  , vmoptBlockGaslimit :: W256
  , vmoptGasprice :: W256
  , vmoptSchedule :: FeeSchedule Word
  , vmoptCreate :: Bool
  } deriving Show

-- | A log entry
data Log = Log Addr [SWord 8] [SymWord]

-- | An entry in the VM's "call/create stack"
data Frame = Frame
  { _frameContext   :: FrameContext
  , _frameState     :: FrameState
  }

-- | Call/create info
data FrameContext
  = CreationContext
    { creationContextCodehash  :: W256
    , creationContextReversion :: Map Addr Contract
    , creationContextSubstate  :: SubState
    }
  | CallContext
    { callContextOffset    :: Word
    , callContextSize      :: Word
    , callContextCodehash  :: W256
    , callContextAbi       :: Maybe Word
    , callContextData      :: [SWord 8]
    , callContextReversion :: Map Addr Contract
    , callContextSubState  :: SubState
    }

-- | The "registers" of the VM along with memory and data stack
data FrameState = FrameState
  { _contract     :: Addr
  , _codeContract :: Addr
  , _code         :: ByteString
  , _pc           :: Int
  , _stack        :: [SymWord]
  , _memory       :: [SWord 8]
  , _memorySize   :: Int
  , _calldata     :: [SWord 8]
  , _callvalue    :: Word
  , _caller       :: Addr
  , _gas          :: Word
  , _returndata   :: [SWord 8]
  , _static       :: Bool
  }

-- | The state that spans a whole transaction
data TxState = TxState
  { _gasprice        :: Word
  , _txgaslimit      :: Word
  , _origin          :: Addr
  , _toAddr          :: Addr
  , _value           :: Word
  , _substate        :: SubState
  , _isCreate        :: Bool
  , _txReversion     :: Map Addr Contract
  }

-- | The "accrued substate" across a transaction
data SubState = SubState
  { _selfdestructs   :: [Addr]
  , _touchedAccounts :: [Addr]
  , _refunds         :: [(Addr, Word)]
  -- in principle we should include logs here, but do not for now
  }

-- | A contract is either in creation (running its "constructor") or
-- post-creation, and code in these two modes is treated differently
-- by instructions like @EXTCODEHASH@, so we distinguish these two
-- code types.
data ContractCode
  = InitCode ByteString     -- ^ "Constructor" code, during contract creation
  | RuntimeCode ByteString  -- ^ "Instance" code, after contract creation
  deriving (Show, Eq)

-- | A contract can either have concrete or symbolic storage
-- depending on what type of execution we are doing
data Storage
  = Concrete (Map Word Word)
  | Symbolic (SArray (WordN 256) (WordN 256))
  deriving (Show)

-- to allow for Eq Contract (which useful for debugging vmtests)
-- we mock an instance of Eq for symbolic storage.
-- It should not (cannot) be used though.
instance Eq Storage where
  (==) (Concrete a) (Concrete b) = a == b
  (==) (Symbolic _) (Concrete _) = False
  (==) (Concrete _) (Symbolic _) = False
  (==) _ _ = error "do not compare two symbolic arrays like this!"

-- | The state of a contract
data Contract = Contract
  { _contractcode :: ContractCode
  , _storage      :: Storage
  , _balance      :: Word
  , _nonce        :: Word
  , _codehash     :: W256
  , _opIxMap      :: Vector Int
  , _codeOps      :: RegularVector.Vector (Int, Op)
  , _external     :: Bool
  , _origStorage  :: Map Word Word
  }

deriving instance Show Contract
deriving instance Eq Contract

-- | Various environmental data
data Env = Env
  { _contracts :: Map Addr Contract
  , _chainId   :: Word
  , _sha3Crack :: Map Word ByteString
  }


-- | Data about the block
data Block = Block
  { _coinbase    :: Addr
  , _timestamp   :: Word
  , _number      :: Word
  , _difficulty  :: Word
  , _gaslimit    :: Word
  , _maxCodeSize :: Word
  , _schedule    :: FeeSchedule Word
  }

blankState :: FrameState
blankState = FrameState
  { _contract     = 0
  , _codeContract = 0
  , _code         = mempty
  , _pc           = 0
  , _stack        = mempty
  , _memory       = mempty
  , _memorySize   = 0
  , _calldata     = mempty
  , _callvalue    = 0
  , _caller       = 0
  , _gas          = 0
  , _returndata   = mempty
  , _static       = False
  }

makeLenses ''FrameState
makeLenses ''Frame
makeLenses ''Block
makeLenses ''TxState
makeLenses ''SubState
makeLenses ''Contract
makeLenses ''Env
makeLenses ''Cache
makeLenses ''Trace
makeLenses ''VM

-- | An "external" view of a contract's bytecode, appropriate for
-- e.g. @EXTCODEHASH@.
bytecode :: Getter Contract ByteString
bytecode = contractcode . to f
  where f (InitCode _)    = BS.empty
        f (RuntimeCode b) = b

instance Semigroup Cache where
  a <> b = Cache
    { _fetched = mappend (view fetched a) (view fetched b),
      _smtquery = mappend (view smtquery a) (view smtquery b)
    }

instance Monoid Cache where
  mempty = Cache { _fetched = mempty,
                   _smtquery = mempty
                 }

-- * Data accessors

currentContract :: VM -> Maybe Contract
currentContract vm =
  view (env . contracts . at (view (state . codeContract) vm)) vm

-- * Data constructors

makeVm :: VMOpts -> VM
makeVm o = VM
  { _result = Nothing
  , _frames = mempty
  , _tx = TxState
    { _gasprice = w256 $ vmoptGasprice o
    , _txgaslimit = w256 $ vmoptGaslimit o
    , _origin = vmoptOrigin o
    , _toAddr = vmoptAddress o
    , _value = w256 $ vmoptValue o
    , _substate = SubState mempty mempty mempty
    , _isCreate = vmoptCreate o
    , _txReversion = Map.fromList
      [(vmoptAddress o, vmoptContract o)]
    }
  , _logs = mempty
  , _traces = Zipper.fromForest []
  , _block = Block
    { _coinbase = vmoptCoinbase o
    , _timestamp = w256 $ vmoptTimestamp o
    , _number = w256 $ vmoptNumber o
    , _difficulty = w256 $ vmoptDifficulty o
    , _maxCodeSize = w256 $ vmoptMaxCodeSize o
    , _gaslimit = w256 $ vmoptBlockGaslimit o
    , _schedule = vmoptSchedule o
    }
  , _state = FrameState
    { _pc = 0
    , _stack = mempty
    , _memory = mempty
    , _memorySize = 0
    , _code = theCode
    , _contract = vmoptAddress o
    , _codeContract = vmoptAddress o
    , _calldata = vmoptCalldata o
    , _callvalue = w256 $ vmoptValue o
    , _caller = vmoptCaller o
    , _gas = w256 $ vmoptGas o
    , _returndata = mempty
    , _static = False
    }
  , _env = Env
    { _sha3Crack = mempty
    , _chainId = 1
    , _contracts = Map.fromList
      [(vmoptAddress o, vmoptContract o)]
    }
  , _cache = Cache (Map.fromList
    [(vmoptAddress o, vmoptContract o)])
    mempty
  , _execMode = ExecuteNormally
  , _burned = 0
  , _pathConditions = []
  } where theCode = case _contractcode (vmoptContract o) of
            InitCode b    -> b
            RuntimeCode b -> b

initialContract :: ContractCode -> Contract
initialContract theContractCode = Contract
  { _contractcode = theContractCode
  , _codehash =
    if BS.null theCode then 0 else
      keccak (stripBytecodeMetadata theCode)
  , _storage  = Concrete mempty
  , _balance  = 0
  , _nonce    = 0
  , _opIxMap  = mkOpIxMap theCode
  , _codeOps  = mkCodeOps theCode
  , _external = False
  , _origStorage = mempty
  } where theCode = case theContractCode of
            InitCode b    -> b
            RuntimeCode b -> b

-- * Opcode dispatch (exec1)

next :: (?op :: Word8) => EVM ()
next = modifying (state . pc) (+ (opSize ?op))

w256lit :: W256 -> SymWord
w256lit = S Dull . literal . toSizzle

litWord :: Word -> (SymWord)
litWord (C whiff a) = S whiff (literal $ toSizzle a)

-- TODO: wrap these up with the state as well
-- for more insightful failure mode
forceLit :: SymWord -> Word
forceLit (S whiff a) = case unliteral a of
  Just c -> C whiff (fromSizzle c)
  Nothing -> error "unexpected symbolic argument"

forceLitBytes :: [SWord 8] -> ByteString
forceLitBytes = BS.pack . fmap (fromSized . fromJust . unliteral)

maybeLitBytes :: [SWord 8] -> Maybe ByteString
maybeLitBytes xs = fmap (\x -> BS.pack (fmap fromSized x)) (mapM unliteral xs)

exec1 :: EVM ()
exec1 = do
  vm <- get

  let
    -- Convenience function to access parts of the current VM state.
    -- Arcane type signature needed to avoid monomorphism restriction.
    the :: (b -> VM -> Const a VM) -> ((a -> Const a a) -> b) -> a
    the f g = view (f . g) vm

    -- Convenient aliases
    mem  = the state memory
    stk  = the state stack
    self = the state contract
    this = fromMaybe (error "internal error: state contract") (preview (ix (the state contract)) (the env contracts))

    fees@(FeeSchedule {..}) = the block schedule

    doStop = finishFrame (FrameReturned [])

  if self > 0x0 && self <= 0x9 then do
    -- call to precompile
    let ?op = 0x00 -- dummy value
    let
      calldatasize = num $ length (the state calldata)
    copyBytesToMemory (the state calldata) calldatasize 0 0
    executePrecompile fees self (the state gas) 0 calldatasize 0 0 []
    vmx <- get
    case view (state.stack) vmx of
      (x:_) -> case maybeLitWord x of
        Just 0 -> do
          fetchAccount self $ \_ -> do
            touchAccount self
            vmError PrecompileFailure
        Just _ ->
          fetchAccount self $ \_ -> do
            touchAccount self
            out <- use (state . returndata)
            finishFrame (FrameReturned out)
        Nothing -> vmError UnexpectedSymbolicArg
      _ ->
        underrun

  else if the state pc >= num (BS.length (the state code))
    then doStop

    else do
      let ?op = BS.index (the state code) (the state pc)

      case ?op of

        -- op: PUSH
        x | x >= 0x60 && x <= 0x7f -> do
          let !n = num x - 0x60 + 1
              !xs = BS.take n (BS.drop (1 + the state pc)
                                       (the state code))
          limitStack 1 $
            burn g_verylow $ do
              next
              push (w256 (word xs))

        -- op: DUP
        x | x >= 0x80 && x <= 0x8f -> do
          let !i = x - 0x80 + 1
          case preview (ix (num i - 1)) stk of
            Nothing -> underrun
            Just y -> do
              limitStack 1 $
                burn g_verylow $ do
                  next
                  pushSym y

        -- op: SWAP
        x | x >= 0x90 && x <= 0x9f -> do
          let i = num (x - 0x90 + 1)
          if length stk < i + 1
            then underrun
            else
              burn g_verylow $ do
                next
                zoom (state . stack) $ do
                  assign (ix 0) (stk ^?! ix i)
                  assign (ix i) (stk ^?! ix 0)

        -- op: LOG
        x | x >= 0xa0 && x <= 0xa4 ->
          notStatic $
          let n = (num x - 0xa0) in
          case stk of
            ((forceLit -> xOffset):(forceLit -> xSize):xs) ->
              if length xs < n
              then underrun
              else do
                let (topics, xs') = splitAt n xs
                    bytes         = readMemory (num xOffset) (num xSize) vm
                    log           = Log self bytes topics

                burn (g_log + g_logdata * xSize + num n * g_logtopic) $ do
                  accessMemoryRange fees xOffset xSize $ do
                    traceLog log
                    next
                    assign (state . stack) xs'
                    pushToSequence logs log
            _ ->
              underrun

        -- op: STOP
        0x00 -> doStop

        -- op: ADD
        0x01 -> stackOp2 (const g_verylow) (uncurry (+))
        -- op: MUL
        0x02 -> stackOp2 (const g_low) (uncurry (*))
        -- op: SUB
        0x03 -> stackOp2 (const g_verylow) (uncurry (-))

        -- op: DIV
        0x04 -> stackOp2 (const g_low) (uncurry (sDiv))

        -- op: SDIV
        0x05 ->
          stackOp2 (const g_low) (uncurry (sdiv))

        -- op: MOD
        0x06 -> stackOp2 (const g_low) $ \(x, y) -> ite (y .== 0) 0 (x `sMod` y)

        -- op: SMOD
        0x07 -> stackOp2 (const g_low) $ uncurry smod
        -- op: ADDMOD
        0x08 -> stackOp3 (const g_mid) $ (\(x, y, z) -> addmod x y z)
        -- op: MULMOD
        0x09 -> stackOp3 (const g_mid) $ (\(x, y, z) -> mulmod x y z)

        -- op: LT
        0x10 -> stackOp2 (const g_verylow) $ \(x, y) -> ite (x .< y) 1 0
        -- op: GT
        0x11 -> stackOp2 (const g_verylow) $ \(x, y) -> ite (x .> y) 1 0
        -- op: SLT
        0x12 -> stackOp2 (const g_verylow) $ uncurry slt
        -- op: SGT
        0x13 -> stackOp2 (const g_verylow) $ uncurry sgt

        -- op: EQ
        0x14 -> stackOp2 (const g_verylow) $ \(x, y) -> ite (x .== y) 1 0
        -- op: ISZERO
        0x15 -> stackOp1 (const g_verylow) $ \x -> ite (x .== 0) 1 0

        -- op: AND
        0x16 -> stackOp2 (const g_verylow) $ uncurry (.&.)
        -- op: OR
        0x17 -> stackOp2 (const g_verylow) $ uncurry (.|.)
        -- op: XOR
        0x18 -> stackOp2 (const g_verylow) $ uncurry xor
        -- op: NOT
        0x19 -> stackOp1 (const g_verylow) complement

        -- op: BYTE
        0x1a -> stackOp2 (const g_verylow) $ \case
          (n, _) | (forceLit n) >= 32 ->
            0
          (n, x) ->
            0xff .&. shiftR x (8 * (31 - num (forceLit n)))

        -- op: SHL
        0x1b -> stackOp2 (const g_verylow) $ \((S _ n), (S _ x)) -> sw256 $ sShiftLeft x n
        -- op: SHR
        0x1c -> stackOp2 (const g_verylow) $ \((S _ n), (S _ x)) -> sw256 $ sShiftRight x n
        -- op: SAR
        0x1d -> stackOp2 (const g_verylow) $ \((S _ n), (S _ x)) -> sw256 $ sSignedShiftArithRight x n

        -- op: SHA3
        -- more accurately refered to as KECCAK
        0x20 ->
          case stk of
            (((num . forceLit) -> xOffset) : ((num . forceLit) -> xSize) : xs) -> do
              let bytes = readMemory xOffset xSize vm
                  (hash, invMap)  = case maybeLitBytes bytes of
                                 Just bs -> (litWord $ keccakBlob bs, Map.singleton (keccakBlob bs) bs)
                                 Nothing -> error "not supported yet" --symKeccak bytes
              burn (g_sha3 + g_sha3word * ceilDiv (num xSize) 32) $
                accessMemoryRange fees xOffset xSize $ do
                  next
                  assign (state . stack) (hash : xs)
                  (env . sha3Crack) <>= invMap
            _ -> underrun

        -- op: ADDRESS
        0x30 ->
          limitStack 1 $
            burn g_base (next >> push (num (the state contract)))

        -- op: BALANCE
        0x31 ->
          case stk of
            (x:xs) -> do
              burn g_balance $ do
                fetchAccount (num (forceLit x)) $ \c -> do
                  next
                  assign (state . stack) xs
                  push (view balance c)
            [] ->
              underrun

        -- op: ORIGIN
        0x32 ->
          limitStack 1 . burn g_base $
            next >> push (num (the tx origin))

        -- op: CALLER
        0x33 ->
          limitStack 1 . burn g_base $
            next >> push (num (the state caller))

        -- op: CALLVALUE
        0x34 ->
          limitStack 1 . burn g_base $
            next >> push (the state callvalue)

        -- op: CALLDATALOAD
        0x35 -> stackOp1 (const g_verylow) $
          \x -> readSWord (forceLit x) (the state calldata)

        -- op: CALLDATASIZE
        0x36 ->
          limitStack 1 . burn g_base $
            next >> push (num (length (the state calldata)))

        -- op: CALLDATACOPY
        0x37 ->
          case stk of
            (((num . forceLit) -> xTo) : ((num . forceLit) -> xFrom) : ((num . forceLit) -> xSize) :xs) -> do
              burn (g_verylow + g_copy * ceilDiv xSize 32) $ do
                accessUnboundedMemoryRange fees xTo xSize $ do
                  next
                  assign (state . stack) xs
                  copyBytesToMemory (the state calldata) xSize xFrom xTo
            _ -> underrun

        -- op: CODESIZE
        0x38 ->
          limitStack 1 . burn g_base $
            next >> push (num (BS.length (the state code)))

        -- op: CODECOPY
        0x39 ->
          case stk of
            (((num . forceLit) -> memOffset) : ((num . forceLit) -> codeOffset) : ((num . forceLit) -> n) : xs) -> do
              burn (g_verylow + g_copy * ceilDiv (num n) 32) $ do
                accessUnboundedMemoryRange fees memOffset n $ do
                  next
                  assign (state . stack) xs
                  copyBytesToMemory (litBytes (the state code))
                    n codeOffset memOffset
            _ -> underrun

        -- op: GASPRICE
        0x3a ->
          limitStack 1 . burn g_base $
            next >> push (the tx gasprice)

        -- op: EXTCODESIZE
        0x3b ->
          case stk of
            ((forceLit -> x):xs) -> do
              if x == num cheatCode
                then do
                  next
                  assign (state . stack) xs
                  push (w256 1)
                else
                  burn g_extcode $ do
                    fetchAccount (num x) $ \c -> do
                      next
                      assign (state . stack) xs
                      push (num (BS.length (view bytecode c)))
            [] ->
              underrun

        -- op: EXTCODECOPY
        0x3c ->
          case stk of
            ( (forceLit -> extAccount)
              : (num . forceLit -> memOffset)
              : (num . forceLit -> codeOffset)
              : (num . forceLit -> codeSize)
              : xs ) -> do
              burn (g_extcode + g_copy * ceilDiv (num codeSize) 32) $
                accessUnboundedMemoryRange fees memOffset codeSize $ do
                  fetchAccount (num extAccount) $ \c -> do
                    next
                    assign (state . stack) xs
                    copyBytesToMemory (litBytes (view bytecode c))
                      codeSize codeOffset memOffset
            _ -> underrun

        -- op: RETURNDATASIZE
        0x3d ->
          limitStack 1 . burn g_base $
            next >> push (num $ length (the state returndata))

        -- op: RETURNDATACOPY
        0x3e ->
          case stk of
            ((num . forceLit -> xTo) : (num . forceLit -> xFrom) : (num . forceLit -> xSize) :xs) -> do
              burn (g_verylow + g_copy * ceilDiv xSize 32) $ do
                accessUnboundedMemoryRange fees xTo xSize $ do
                  next
                  assign (state . stack) xs
                  if length (the state returndata) < num xFrom + num xSize
                  then vmError InvalidMemoryAccess
                  else copyBytesToMemory (the state returndata) xSize xFrom xTo
            _ -> underrun

        -- op: EXTCODEHASH
        0x3f ->
          case stk of
            ((forceLit -> x):xs) -> do
              burn g_extcodehash $ do
                next
                assign (state . stack) xs
                fetchAccount (num x) $ \c -> do
                   if accountEmpty c
                     then push (num (0 :: Int))
                     else push (num (keccak (view bytecode c)))
            [] ->
              underrun

        -- op: BLOCKHASH
        0x40 -> do
          -- We adopt the fake block hash scheme of the VMTests,
          -- so that blockhash(i) is the hash of i as decimal ASCII.
          stackOp1 (const g_blockhash) $
            \(forceLit -> i) ->
              if i + 256 < the block number || i >= the block number
              then 0
              else
                (num i :: Integer)
                  & show & Char8.pack & keccak & num

        -- op: COINBASE
        0x41 ->
          limitStack 1 . burn g_base $
            next >> push (num (the block coinbase))

        -- op: TIMESTAMP
        0x42 ->
          limitStack 1 . burn g_base $
            next >> push (the block timestamp)

        -- op: NUMBER
        0x43 ->
          limitStack 1 . burn g_base $
            next >> push (the block number)

        -- op: DIFFICULTY
        0x44 ->
          limitStack 1 . burn g_base $
            next >> push (the block difficulty)

        -- op: GASLIMIT
        0x45 ->
          limitStack 1 . burn g_base $
            next >> push (the block gaslimit)

        -- op: CHAINID
        0x46 ->
          limitStack 1 . burn g_base $
            next >> push (the env chainId)

        -- op: SELFBALANCE
        0x47 ->
          limitStack 1 . burn g_low $
            next >> push (view balance this)

        -- op: POP
        0x50 ->
          case stk of
            (_:xs) -> burn g_base (next >> assign (state . stack) xs)
            _      -> underrun

        -- op: MLOAD
        0x51 ->
          case stk of
            (x:xs) -> do
              burn g_verylow $
                accessMemoryWord fees (forceLit x) $ do
                  next
                  assign (state . stack) (view (word256At (num (forceLit x))) mem : xs)
            _ -> underrun

        -- op: MSTORE
        0x52 ->
          case stk of
            ((forceLit -> x):y:xs) -> do
              burn g_verylow $
                accessMemoryWord fees x $ do
                  next
                  assign (state . memory . word256At (num x)) y
                  assign (state . stack) xs
            _ -> underrun

        -- op: MSTORE8
        0x53 ->
          case stk of
            ((forceLit -> x):(S _ y):xs) -> do
              let yByte = bvExtract (Proxy :: Proxy 7) (Proxy :: Proxy 0) y
              burn g_verylow $
                accessMemoryRange fees x 1 $ do
                  next
                  modifying (state . memory) (setMemoryByte x yByte)
                  assign (state . stack) xs
            _ -> underrun

        -- op: SLOAD
        0x54 ->
          case stk of
            (x:xs) ->
              burn g_sload $
                accessStorage self x $ \y -> do
                  next
                  assign (state . stack) (y:xs)
            _ -> underrun

        -- op: SSTORE
        0x55 ->
          notStatic $
          case stk of
            (x:new:xs) -> do
              accessStorage self x $ \current -> do
                availableGas <- use (state . gas)

                if availableGas <= g_callstipend
                  then finishFrame (FrameErrored (OutOfGas availableGas g_callstipend))
                  else do
                    let original = case view storage this of
                                      Concrete _ -> fromMaybe 0 (Map.lookup (forceLit x) (view origStorage this))
                                      Symbolic _ -> 0 -- we don't use this value anywhere anyway
                    let cost = case mapM maybeLitWord (current:new:[]) of
                                 -- if any of the arguments are symbolic,
                                 -- assume worst case scenario
                                 Nothing -> g_sset
                                 Just (current':new':[]) -> 
                                    if (current' == new') then g_sload
                                    else if (current' == original) && (original == 0) then g_sset
                                    else if (current' == original) then g_sreset
                                    else g_sload

                    burn cost $ do
                      next
                      assign (state . stack) xs
                      modifying (env . contracts . ix (the state contract) . storage)
                        (writeStorage x new)
                      case mapM maybeLitWord [current,new] of
                         -- if any of the arguments are symbolic,
                         -- don't mess with the refund counter
                         Nothing -> noop
                         Just (current':new':[]) ->
                            if current' == new'
                            then noop
                            else if current' == original
                                 then if original /= 0 && new' == 0
                                      then refund r_sclear
                                      else noop
                                 else do
                                         if original /= 0
                                         then if new' == 0
                                              then refund r_sclear
                                              else unRefund r_sclear
                                         else noop

                                         if original == new'
                                         then if original == 0
                                              then refund (g_sset - g_sload)
                                              else refund (g_sreset - g_sload)
                                         else noop

            _ -> underrun

        -- op: JUMP
        0x56 ->
          case stk of
            (x:xs) -> do
              burn g_mid $ do
                checkJump (forceLit x) xs
            _ -> underrun

        -- op: JUMPI
        0x57 -> do
          case stk of
            (x:y:xs) -> do
                burn g_high $ do
                  let jump z = if z == 0
                               then assign (state . stack) xs >> next
                               else checkJump (forceLit x) xs                                
                  case maybeLitWord y of
                      Just y' -> jump y'
                      -- if the jump condition is symbolic, an smt query has to be made.
                      Nothing -> askSMT self (num $ the state pc) y jump
            _ -> underrun

        -- op: PC
        0x58 ->
          limitStack 1 . burn g_base $
            next >> push (num (the state pc))

        -- op: MSIZE
        0x59 ->
          limitStack 1 . burn g_base $
            next >> push (num (the state memorySize))

        -- op: GAS
        0x5a ->
          limitStack 1 . burn g_base $
            next >> push (the state gas - g_base)

        -- op: JUMPDEST
        0x5b -> burn g_jumpdest next

        -- op: EXP
        0x0a ->
          let cost (_ ,(forceLit -> exponent)) =
                if exponent == 0
                then g_exp
                else g_exp + g_expbyte * num (ceilDiv (1 + log2 exponent) 8)
          in stackOp2 cost $ \((S _ x),(S _ y)) -> sw256 $ x .^ y

        -- op: SIGNEXTEND
        0x0b ->
          stackOp2 (const g_low) $ \((forceLit -> bytes), w@(S _ x)) ->
            if bytes >= 32 then w
            else let n = num bytes * 8 + 7 in
              sw256 $ ite (sTestBit x n)
                      (x .|. complement (bit n - 1))
                      (x .&. (bit n - 1))

        -- op: CREATE
        0xf0 ->
          notStatic $
          case stk of
            ((forceLit -> xValue):(forceLit -> xOffset):(forceLit -> xSize):xs) ->
              accessMemoryRange fees xOffset xSize $ do
                availableGas <- use (state . gas)
                let
                  initCode = forceLitBytes $ readMemory (num xOffset) (num xSize) vm
                  newAddr = createAddress self (wordValue (view nonce this))
                  (cost, gas') = costOfCreate fees availableGas 0
                burn (cost - gas') $
                  create self this gas' xValue xs newAddr initCode
            _ -> underrun

        -- op: CALL
        0xf1 ->
          case stk of
            ( (forceLit -> xGas)
              : (num . forceLit -> xTo)
              : (forceLit -> xValue)
              : (forceLit -> xInOffset)
              : (forceLit -> xInSize)
              : (forceLit -> xOutOffset)
              : (forceLit -> xOutSize)
              : xs
             ) ->
              (if xValue > 0 then notStatic else id) $
              case xTo of
                n | n > 0 && n <= 9 ->
                  precompiledContract vm fees xGas xTo xTo xValue xInOffset xInSize xOutOffset xOutSize xs
                n | num n == cheatCode ->
                  do
                    assign (state . stack) xs
                    cheat (xInOffset, xInSize) (xOutOffset, xOutSize)
                _ ->
                    accessMemoryRange fees xInOffset xInSize $
                      accessMemoryRange fees xOutOffset xOutSize $ do
                        availableGas <- use (state . gas)
                        let
                          recipientExists = accountExists xTo vm
                          (cost, gas') = costOfCall fees recipientExists xValue availableGas xGas
                        burn (cost - gas') $
                          delegateCall this gas' xTo xValue xInOffset xInSize xOutOffset xOutSize xs $ do
                            zoom state $ do
                              assign callvalue xValue
                              assign caller (the state contract)
                              assign contract xTo
                            zoom (env . contracts) $ do
                              ix self . balance -= xValue
                              ix xTo  . balance += xValue
                            touchAccount self
                            touchAccount xTo
            _ ->
              underrun

        -- op: CALLCODE
        0xf2 ->
          case stk of
            ( (forceLit -> xGas)
              : (num . forceLit -> xTo)
              : (forceLit -> xValue)
              : (forceLit -> xInOffset)
              : (forceLit -> xInSize)
              : (forceLit -> xOutOffset)
              : (forceLit -> xOutSize)
              : xs
              ) ->
              case xTo of
                n | n > 0 && n <= 9 ->
                  precompiledContract vm fees xGas xTo self xValue xInOffset xInSize xOutOffset xOutSize xs
                _ ->
                  accessMemoryRange fees xInOffset xInSize $
                    accessMemoryRange fees xOutOffset xOutSize $ do
                      availableGas <- use (state . gas)
                      let
                        (cost, gas') = costOfCall fees True xValue availableGas xGas
                      burn (cost - gas') $
                        delegateCall this gas' xTo xValue xInOffset xInSize xOutOffset xOutSize xs $ do
                          zoom state $ do
                            assign callvalue xValue
                            assign caller (the state contract)
                          touchAccount self
            _ ->
              underrun

        -- op: RETURN
        0xf3 ->
          case stk of
            ((forceLit -> xOffset):(forceLit -> xSize):_) ->
              accessMemoryRange fees xOffset xSize $ do
                let
                  output = readMemory xOffset xSize vm
                  codesize = num (length output)
                  maxsize = the block maxCodeSize
                case view frames vm of
                  [] ->
                    case (the tx isCreate) of
                      True ->
                        if codesize > maxsize
                        then do
                          finishFrame (FrameErrored (MaxCodeSizeExceeded maxsize codesize))
                        else
                          burn (g_codedeposit * num (length output)) $
                            finishFrame (FrameReturned output)
                      False ->
                        finishFrame (FrameReturned output)
                  (frame: _) -> do
                    let
                      context = view frameContext frame
                    case context of
                      CreationContext _ _ _ ->
                        if codesize > maxsize
                        then do
                          finishFrame (FrameErrored (MaxCodeSizeExceeded maxsize codesize))
                        else
                          burn (g_codedeposit * num (length output)) $
                            finishFrame (FrameReturned output)
                      CallContext _ _ _ _ _ _ _ ->
                          finishFrame (FrameReturned output)
            _ -> underrun

        -- op: DELEGATECALL
        0xf4 ->
          case stk of
            ((forceLit -> xGas):
             (num . forceLit -> xTo)
             :(forceLit -> xInOffset)
             :(forceLit -> xInSize)
             :(forceLit -> xOutOffset)
             :(forceLit -> xOutSize)
             :xs) ->
              case xTo of
                n | n > 0 && n <= 9 ->
                  precompiledContract vm fees xGas xTo self 0 xInOffset xInSize xOutOffset xOutSize xs
                n | num n == cheatCode -> do
                      assign (state . stack) xs
                      cheat (xInOffset, xInSize) (xOutOffset, xOutSize)
                _ ->
                  accessMemoryRange fees xInOffset xInSize $
                    accessMemoryRange fees xOutOffset xOutSize $ do
                    availableGas <- use (state . gas)
                    let
                      (cost, gas') = costOfCall fees True 0 availableGas xGas
                    burn (cost - gas') $ do
                      theCaller <- use (state . caller)
                      delegateCall this gas' xTo 0 xInOffset xInSize xOutOffset xOutSize xs $ do
                        touchAccount theCaller
                        touchAccount self
            _ -> underrun

        -- op: CREATE2
        0xf5 -> notStatic $
          case stk of
            ((forceLit -> xValue):
             (forceLit -> xOffset):
             (forceLit -> xSize):
             (forceLit -> xSalt):
              xs) ->
              accessMemoryRange fees xOffset xSize $ do
                availableGas <- use (state . gas)
                let
                  initCode = forceLitBytes $ readMemory (num xOffset) (num xSize) vm
                  newAddr  = create2Address self (num xSalt) initCode
                  (cost, gas') = costOfCreate fees availableGas xSize
                burn (cost - gas') $
                  create self this gas' xValue xs newAddr initCode
            _ -> underrun

        -- op: STATICCALL
        0xfa ->
          case stk of
            ((forceLit -> xGas) : (num . forceLit -> xTo) : (forceLit -> xInOffset) : (forceLit -> xInSize) : (forceLit -> xOutOffset) : (forceLit -> xOutSize) : xs) ->
              case xTo of
                n | n > 0 && n <= 9 ->
                  precompiledContract vm fees xGas xTo xTo 0 xInOffset xInSize xOutOffset xOutSize xs
                _ ->
                  accessMemoryRange fees xInOffset xInSize $
                    accessMemoryRange fees xOutOffset xOutSize $ do
                      availableGas <- use (state . gas)
                      let
                        recipientExists = accountExists xTo vm
                        (cost, gas') = costOfCall fees recipientExists 0 availableGas xGas
                      burn (cost - gas') $
                        delegateCall this gas' xTo 0 xInOffset xInSize xOutOffset xOutSize xs $ do
                          zoom state $ do
                            assign callvalue 0
                            assign caller (the state contract)
                            assign contract xTo
                            assign static True
                          touchAccount self
                          touchAccount xTo
            _ ->
              underrun

        -- op: SELFDESTRUCT
        0xff ->
          notStatic $
          case stk of
            [] -> underrun
            ((num . forceLit -> xTo):_) ->
              let
                recipientExists = accountExists xTo vm
                c_new = if not recipientExists && view balance this /= 0
                        then num g_selfdestruct_newaccount
                        else 0
              in burn (g_selfdestruct + c_new) $ do
                destructs <- use (tx . substate . selfdestructs)
                if elem self destructs then noop else do refund r_selfdestruct
                selfdestruct self
                touchAccount xTo

                let funds = (vm ^?! env . contracts . ix self . balance)
                if funds == 0
                  then
                    doStop
                else if self == xTo
                  then do
                    assign (env . contracts . ix self . balance) 0
                    doStop
                else
                  fetchAccount xTo $ \_ -> do
                    assign (env . contracts . ix self . balance) 0
                    modifying (env . contracts . ix xTo . balance)
                      (+ (vm ^?! env . contracts . ix self . balance))
                    doStop

        -- op: REVERT
        0xfd ->
          case stk of
            ((forceLit -> xOffset):(forceLit -> xSize):_) ->
              accessMemoryRange fees xOffset xSize $ do
                let output = readMemory xOffset xSize vm
                finishFrame (FrameReverted output)
            _ -> underrun

        xxx ->
          vmError (UnrecognizedOpcode xxx)

precompiledContract
  :: (?op :: Word8)
  => VM
  -> FeeSchedule Word
  -> Word
  -> Addr
  -> Addr
  -> Word
  -> Word -> Word -> Word -> Word
  -> [SymWord]
  -> EVM ()
precompiledContract vm fees gasCap precompileAddr recipient xValue inOffset inSize outOffset outSize xs =
    accessMemoryRange fees inOffset inSize $
      accessMemoryRange fees outOffset outSize $ do
        availableGas <- use (state . gas)
        let
          self = view (state . contract) vm
          Just this = view (env . contracts . at self) vm
          recipientExists = accountExists recipient vm
          (cost, gas') = costOfCall fees recipientExists xValue availableGas gasCap
        burn (cost - gas') $
          if xValue > view balance this then do
            assign (state . stack) (0 : xs)
            next
          else do
            executePrecompile fees precompileAddr gas' inOffset inSize outOffset outSize xs
            stk <- use (state . stack)
            case stk of
              (x:_) -> case maybeLitWord x of
                Nothing -> vmError UnexpectedSymbolicArg
                Just 0 -> 
                  return ()
                Just 1 ->
                  fetchAccount recipient $ \_ -> do

                     zoom (env . contracts) $ do
                       ix self . balance -= xValue
                       ix recipient  . balance += xValue
                     touchAccount self
                     touchAccount recipient
                     touchAccount precompileAddr
              _ ->
                underrun

executePrecompile
  :: (?op :: Word8)
  => FeeSchedule Word
  -> Addr
  -> Word -> Word -> Word -> Word -> Word -> [SymWord]
  -> EVM ()
executePrecompile fees preCompileAddr gasCap inOffset inSize outOffset outSize xs  = do
  vm <- get
  let input = forceLitBytes $ readMemory (num inOffset) (num inSize) vm
      cost = costOfPrecompile fees preCompileAddr input
      notImplemented = error $ "precompile at address " <> show preCompileAddr <> " not yet implemented"
      precompileFail = do burn (gasCap - cost) $ do
                            assign (state . stack) (0 : xs)
                            pushTrace $ ErrorTrace $ PrecompileFailure
                            next
  if cost > gasCap then
    burn gasCap $ do
      assign (state . stack) (0 : xs)
      next
  else
    burn cost $
      case preCompileAddr of
        -- ECRECOVER
        0x1 ->
          case EVM.Precompiled.execute 0x1 (truncpadlit 128 input) 32 of
            Nothing -> do
              -- return no output for invalid signature
              assign (state . stack) (1 : xs)
              assign (state . returndata) mempty
              next
            Just (litBytes -> output) -> do
              assign (state . stack) (1 : xs)
              assign (state . returndata) output
              copyBytesToMemory output outSize 0 outOffset
              next

        -- SHA2-256
        0x2 ->
          let
            hash  = litBytes $ BS.pack $ BA.unpack $ (Crypto.hash input :: Digest SHA256)
          in do
            assign (state . stack) (1 : xs)
            assign (state . returndata) hash
            copyBytesToMemory hash outSize 0 outOffset
            next

        -- RIPEMD-160
        0x3 ->
          let
            padding = BS.pack $ replicate 12 0
            hash' = BS.pack $ BA.unpack $ (Crypto.hash input :: Digest RIPEMD160)
            hash  = litBytes $ padding <> hash'
          in do
            assign (state . stack) (1 : xs)
            assign (state . returndata) hash
            copyBytesToMemory hash outSize 0 outOffset
            next

        -- IDENTITY
        0x4 -> do
            let out = litBytes input
            assign (state . stack) (1 : xs)
            assign (state . returndata) out -- could be symbolic
            copyCallBytesToMemory out outSize 0 outOffset
            next

        -- MODEXP
        0x5 ->
          let
            (lenb, lene, lenm) = parseModexpLength input

            output = litBytes $
              case (isZero (96 + lenb + lene) lenm input) of
                 True ->
                   truncpadlit (num lenm) (asBE (0 :: Int))
                 False ->
                   let
                     b = asInteger $ lazySlice 96 lenb $ input
                     e = asInteger $ lazySlice (96 + lenb) lene $ input
                     m = asInteger $ lazySlice (96 + lenb + lene) lenm $ input
                   in
                     padLeft (num lenm) (asBE (expFast b e m))
          in do
            assign (state . stack) (1 : xs)
            assign (state . returndata) output
            copyBytesToMemory output outSize 0 outOffset
            next

        -- ECADD
        0x6 -> case EVM.Precompiled.execute 0x6 (truncpadlit 128 input) 64 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = litBytes $ truncpadlit 64 output
            assign (state . stack) (1 : xs)
            assign (state . returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput outSize 0 outOffset
            next

        -- ECMUL
        0x7 -> case EVM.Precompiled.execute 0x7 (truncpadlit 96 input) 64 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = litBytes $ truncpadlit 64 output
            assign (state . stack) (1 : xs)
            assign (state . returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput outSize 0 outOffset
            next

        -- ECPAIRING
        0x8 -> case EVM.Precompiled.execute 0x8 input 32 of
          Nothing -> precompileFail
          Just output -> do
            let truncpaddedOutput = litBytes $ truncpadlit 32 output
            assign (state . stack) (1 : xs)
            assign (state . returndata) truncpaddedOutput
            copyBytesToMemory truncpaddedOutput outSize 0 outOffset
            next

        -- BLAKE2
        0x9 -> case (BS.length input, 1 >= BS.last input) of
          (213, True) -> case EVM.Precompiled.execute 0x9 input 64 of
            Just output -> do
              let truncpaddedOutput = litBytes $ truncpadlit 64 output
              assign (state . stack) (1 : xs)
              assign (state . returndata) truncpaddedOutput
              copyBytesToMemory truncpaddedOutput outSize 0 outOffset
              next
            Nothing -> precompileFail
          _ -> precompileFail


        _   -> notImplemented

truncpadlit :: Int -> ByteString -> ByteString
truncpadlit n xs = if m > n then BS.take n xs
                   else BS.append xs (BS.replicate (n - m) 0)
  where m = BS.length xs

lazySlice :: Word -> Word -> ByteString -> LS.ByteString
lazySlice offset size bs =
  let bs' = LS.take (num size) (LS.drop (num offset) (fromStrict bs))
  in bs' <> LS.replicate ((num size) - LS.length bs') 0

parseModexpLength :: ByteString -> (Word, Word, Word)
parseModexpLength input =
  let lenb = w256 $ word $ LS.toStrict $ lazySlice  0 32 input
      lene = w256 $ word $ LS.toStrict $ lazySlice 32 64 input
      lenm = w256 $ word $ LS.toStrict $ lazySlice 64 96 input
  in (lenb, lene, lenm)

isZero :: Word -> Word -> ByteString -> Bool
isZero offset size bs =
  LS.all (\x -> x == 0) $
    LS.take (num size) $
      LS.drop (num (offset)) $
        fromStrict bs

asInteger :: LS.ByteString -> Integer
asInteger xs = if xs == mempty then 0
  else 256 * asInteger (LS.init xs)
      + (num $ LS.last xs)

-- * Opcode helper actions

noop :: Monad m => m ()
noop = pure ()

pushTo :: MonadState s m => ASetter s s [a] [a] -> a -> m ()
pushTo f x = f %= (x :)

pushToSequence :: MonadState s m => ASetter s s (Seq a) (Seq a) -> a -> m ()
pushToSequence f x = f %= (Seq.|> x)

askSMT :: Addr -> Word -> SymWord -> (Word -> EVM ()) -> EVM ()
askSMT addr pcval jumpcondition continue = do
-- First, check the cache if a query has been done already for this
-- particular (contract, pc) combination:
  use (cache . smtquery . at (addr, pcval)) >>= \case
     -- If the query has been done already, select path or select the only available
     Just w -> choosePath w
     -- If this is a new query, do it, cache it, and select path
     Nothing -> do pathconds <- use pathConditions
                   assign result . Just . VMFailure . Query $ PleaseAskSMT
                     jumpcondition (fst <$> pathconds)
                     (\x -> do assign (cache . smtquery . ix (addr, pcval)) x
                               choosePath x)
   where -- Only one path is possible
         choosePath (Known w) = do assign result Nothing
                                   continue w
         -- Both paths are possible; we ask for more input
         choosePath Unknown = assign result . Just . VMFailure . Query $ PleaseChoosePath
           (\selected -> do
               pathConditions <>= [(litWord selected .== jumpcondition, selected == 1)]
               assign result Nothing
               continue selected)


fetchAccount :: Addr -> (Contract -> EVM ()) -> EVM ()
fetchAccount addr continue = do
  use (env . contracts . at addr) >>= \case
    Just c -> continue c
    Nothing ->
      use (cache . fetched . at addr) >>= \case
        Just c -> do
          assign (env . contracts . at addr) (Just c)
          continue c
        Nothing ->
          assign result . Just . VMFailure . Query $
            PleaseFetchContract addr
              (\c -> do assign (cache . fetched . at addr) (Just c)
                        assign (env . contracts . at addr) (Just c)
                        assign result Nothing
                        tryContinue c)
  where
    tryContinue c =
      if (view external c) && (accountEmpty c)
        then vmError . NoSuchContract $ addr
        else continue c

readStorage :: Storage -> SymWord -> Maybe (SymWord)
readStorage (Symbolic s) (S _ loc) = Just . sw256 $ readArray s loc
readStorage (Concrete s) loc = do v <- Map.lookup (forceLit loc) s
                                  return $ litWord v

writeStorage :: SymWord -> SymWord -> Storage -> Storage
writeStorage (S _ loc) (S _ val) (Symbolic s) = Symbolic (writeArray s loc val)
writeStorage loc val (Concrete s) = Concrete (Map.insert (forceLit loc) (forceLit val) s)

accessStorage
  :: Addr                  -- ^ Contract address
  -> SymWord             -- ^ Storage slot key
  -> (SymWord -> EVM ()) -- ^ Continuation
  -> EVM ()
accessStorage addr slot continue =
  use (env . contracts . at addr) >>= \case
    Just c ->
      case readStorage (view storage c) slot of
        Just x ->
          continue x
        Nothing ->
          if view external c
          then
            -- check if the slot is cached
            use (cache . fetched . at addr) >>= \case
              Nothing -> mkQuery
              Just cachedContract ->
                case readStorage (view storage cachedContract) slot of
                  Nothing -> mkQuery
                  Just x -> continue x
          else do
            modifying (env . contracts . ix addr . storage) (writeStorage slot 0)
            continue 0
    Nothing ->
      fetchAccount addr $ \_ ->
        accessStorage addr slot continue
  where
      mkQuery = assign result . Just . VMFailure . Query $
                  PleaseFetchSlot addr (forceLit slot)
                    (\(litWord -> x) -> do
                        modifying (cache . fetched . ix addr . storage) (writeStorage slot x)
                        modifying (env . contracts . ix addr . storage) (writeStorage slot x)
                        assign result Nothing
                        continue x)

accountExists :: Addr -> VM -> Bool
accountExists addr vm =
  case view (env . contracts . at addr) vm of
    Just c -> not (accountEmpty c)
    Nothing -> False

-- EIP 161
accountEmpty :: Contract -> Bool
accountEmpty c =
  (view contractcode c == RuntimeCode mempty)
  && (view nonce c == 0)
  && (view balance c == 0)

-- * How to finalize a transaction
finalize :: EVM ()
finalize = do
  let
    burnRemainingGas = use (state . gas) >>= (flip burn (noop))
    revertContracts  = use (tx . txReversion) >>= assign (env . contracts)
    revertSubstate   = assign (tx . substate) (SubState mempty mempty mempty)

  use result >>= \case
    Nothing ->
      error "Finalising an unfinished tx."
    Just (VMFailure (Revert _)) -> do
      revertContracts
      revertSubstate
    Just (VMFailure _) -> do
      burnRemainingGas
      revertContracts
      revertSubstate
    Just (VMSuccess output) -> do
      -- deposit the code from a creation tx
      creation <- use (tx . isCreate)
      createe  <- use (state . contract)
      createeExists <- (Map.member createe) <$> use (env . contracts)
      if (creation && createeExists)
      then replaceCode createe (RuntimeCode $ forceLitBytes output)
      else noop

  use execMode >>= \case
    ExecuteAsVMTest ->
      noop
    _ -> do
      -- compute and pay the refund to the caller and the
      -- corresponding payment to the miner
      txOrigin     <- use (tx . origin)
      sumRefunds   <- (sum . (snd <$>)) <$> (use (tx . substate . refunds))
      miner        <- use (block . coinbase)
      blockReward  <- r_block <$> (use (block . schedule))
      gasPrice     <- use (tx . gasprice)
      gasLimit     <- use (tx . txgaslimit)
      gasRemaining <- use (state . gas)

      let
        gasUsed      = gasLimit - gasRemaining
        cappedRefund = min (quot gasUsed 2) sumRefunds
        originPay    = (gasRemaining + cappedRefund) * gasPrice
        minerPay     = gasPrice * (gasUsed - cappedRefund)

      modifying (env . contracts)
        (Map.adjust (over balance (+ originPay)) txOrigin)
      modifying (env . contracts)
        (Map.adjust (over balance (+ minerPay)) miner)
      touchAccount miner

      -- pay out the block reward, recreating the miner if necessary
      preuse (env . contracts . ix miner) >>= \case
        Nothing -> modifying (env . contracts)
          (Map.insert miner (initialContract (EVM.RuntimeCode mempty)))
        Just _  -> noop
      modifying (env . contracts)
        (Map.adjust (over balance (+ blockReward)) miner)

  -- perform state trie clearing (EIP 161), of selfdestructs
  -- and touched accounts. addresses are cleared if they have
  --    a) selfdestructed, or
  --    b) been touched and
  --    c) are empty.
  -- (see Yellow Paper "Accrued Substate")
  --
  -- remove any destructed addresses
  destroyedAddresses <- use (tx . substate . selfdestructs)
  modifying (env . contracts)
    (Map.filterWithKey (\k _ -> not (elem k destroyedAddresses)))
  -- then, clear any remaining empty and touched addresses
  touchedAddresses <- use (tx . substate . touchedAccounts)
  modifying (env . contracts)
    (Map.filterWithKey
      (\k a -> not ((elem k touchedAddresses) && accountEmpty a)))

loadContract :: Addr -> EVM ()
loadContract target =
  preuse (env . contracts . ix target . contractcode) >>=
    \case
      Nothing ->
        error "Call target doesn't exist"
      Just (InitCode targetCode) -> do
        assign (state . contract) target
        assign (state . code)     targetCode
        assign (state . codeContract) target
      Just (RuntimeCode targetCode) -> do
        assign (state . contract) target
        assign (state . code)     targetCode
        assign (state . codeContract) target

limitStack :: Int -> EVM () -> EVM ()
limitStack n continue = do
  stk <- use (state . stack)
  if length stk + n > 1024
    then vmError StackLimitExceeded
    else continue

notStatic :: EVM () -> EVM ()
notStatic continue = do
  bad <- use (state . static)
  if bad
    then vmError StateChangeWhileStatic
    else continue

burn :: Word -> EVM () -> EVM ()
burn n continue = do
  available <- use (state . gas)
  if n <= available
    then do
      state . gas -= n
      burned += n
      continue
    else
      vmError (OutOfGas available n)

-- * Substate manipulation
refund :: Word -> EVM ()
refund n = do
  self <- use (state . contract)
  pushTo (tx . substate . refunds) (self, n)

unRefund :: Word -> EVM ()
unRefund n = do
  self <- use (state . contract)
  refs <- use (tx . substate . refunds)
  assign (tx . substate . refunds)
    (filter (\(a,b) -> not (a == self && b == n)) refs)

touchAccount :: Addr -> EVM()
touchAccount a =
  pushTo ((tx . substate) . touchedAccounts) a

selfdestruct :: Addr -> EVM()
selfdestruct a =
  pushTo ((tx . substate) . selfdestructs) a

-- * Cheat codes

-- The cheat code is 7109709ecfa91a80626ff3989d68f67f5b1dd12d.
-- Call this address using one of the cheatActions below to do
-- special things, e.g. changing the block timestamp. Beware that
-- these are necessarily hevm specific.
cheatCode :: Addr
cheatCode = num (keccak "hevm cheat code")

cheat
  :: (?op :: Word8)
  => (Word, Word) -> (Word, Word)
  -> EVM ()
cheat (inOffset, inSize) (outOffset, outSize) = do
  mem <- use (state . memory)
  vm <- get
  let abi = num (wordValue (forceLit (readMemoryWord32 inOffset mem)))
      input = readMemory (inOffset + 4) (inSize - 4) vm
  case Map.lookup abi cheatActions of
    Nothing ->
      vmError (BadCheatCode abi)
    Just (argTypes, action) -> do
      case runGetOrFail
             (getAbiSeq (length argTypes) argTypes)
             (LS.fromStrict $ forceLitBytes input) of
        Right ("", _, args) -> do
          action (toList args) >>= \case
            Nothing -> do
              next
              push 1
            Just (litBytes . encodeAbiValue -> bs) -> do
              next
              modifying (state . memory)
                (writeMemory bs outSize 0 outOffset)
              push 1
        Left _ ->
          vmError (BadCheatCode abi)
        Right _ ->
          vmError (BadCheatCode abi)

type CheatAction = ([AbiType], [AbiValue] -> EVM (Maybe AbiValue))

cheatActions :: Map Word32 CheatAction
cheatActions =
  Map.fromList
    [ action "warp(uint256)" [AbiUIntType 256] $
        \[AbiUInt 256 x] -> do
          assign (block . timestamp) (w256 (W256 x))
          return Nothing
    ]
  where
    action s ts f = (abiKeccak s, (ts, f))


-- * General call implementation ("delegateCall")
delegateCall
  :: (?op :: Word8)
  => Contract -> Word -> Addr -> Word -> Word -> Word -> Word -> Word -> [SymWord]
  -> EVM ()
  -> EVM ()
delegateCall this xGas xTo xValue xInOffset xInSize xOutOffset xOutSize xs continue = do
  vm0 <- get
  if xValue > view balance this
  then do
    assign (state . stack) (0 : xs)
    assign (state . returndata) mempty
    pushTrace $ ErrorTrace $ BalanceTooLow xValue (view balance this)
    next
  else if length (view frames vm0) >= 1024
  then do
    assign (state . stack) (0 : xs)
    assign (state . returndata) mempty
    pushTrace $ ErrorTrace $ CallDepthLimitReached
    next
  else case view execMode vm0 of
    ExecuteAsVMTest -> do
      assign (state . stack) (1 : xs)
      next
    _ ->
      fetchAccount xTo . const $
        preuse (env . contracts . ix xTo) >>= \case
          Nothing ->
            vmError (NoSuchContract xTo)
          Just target ->
            burn xGas $ do
              let newContext = CallContext
                    { callContextOffset = xOutOffset
                    , callContextSize = xOutSize
                    , callContextCodehash = view codehash target
                    , callContextReversion = view (env . contracts) vm0
                    , callContextSubState = view (tx . substate) vm0
                    , callContextAbi =
                        if xInSize >= 4
                        then case maybeLitBytes $
                                      take 4 $ drop (num xInOffset) $ (view (state . memory) vm0)
                             of Nothing -> Nothing
                                Just sigBytes -> Just . w256 $ word sigBytes
                        else Nothing
                    , callContextData = (readMemory (num xInOffset) (num xInSize) vm0)
                    }

              pushTrace (FrameTrace newContext)
              next
              vm1 <- get

              pushTo frames $ Frame
                { _frameState = (set stack xs) (view state vm1)
                , _frameContext = newContext
                }

              zoom state $ do
                assign gas xGas
                assign pc 0
                assign code (view bytecode target)
                assign codeContract xTo
                assign stack mempty
                assign memory mempty
                assign memorySize 0
                assign returndata mempty
                assign calldata (readMemory (num xInOffset) (num xInSize) vm0)

              continue

-- * Contract creation

-- EIP 684
collision :: Maybe Contract -> Bool
collision c' = case c' of
  Just c -> (view contractcode c /= RuntimeCode mempty) || (view nonce c /= 0)
  Nothing -> False

create :: (?op :: Word8)
  => Addr -> Contract
  -> Word -> Word -> [SymWord] -> Addr -> ByteString -> EVM ()
create self this xGas xValue xs newAddr initCode = do
  vm0 <- get
  if xValue > view balance this
  then do
    assign (state . stack) (0 : xs)
    assign (state . returndata) mempty
    pushTrace $ ErrorTrace $ BalanceTooLow xValue (view balance this)
    next
  else if length (view frames vm0) >= 1024
  then do
    assign (state . stack) (0 : xs)
    assign (state . returndata) mempty
    pushTrace $ ErrorTrace $ CallDepthLimitReached
    next
  else if collision $ view (env . contracts . at newAddr) vm0
  then burn xGas $ do
    assign (state . stack) (0 : xs)
    modifying (env . contracts . ix self . nonce) succ
    next
  else burn xGas $
    case (view execMode vm0) of
      ExecuteAsVMTest -> do
        assign (state . stack) (num newAddr : xs)
        next
      _ -> do
        touchAccount self
        touchAccount newAddr
        let
          newContract =
            initialContract (InitCode initCode)
          newContext  =
            CreationContext { creationContextCodehash  = view codehash newContract
                            , creationContextReversion = view (env . contracts) vm0
                            , creationContextSubstate = view (tx . substate) vm0
                            }

        zoom (env . contracts) $ do
          oldAcc <- use (at newAddr)
          let oldBal = case oldAcc of
                Nothing -> 0
                Just c  -> view balance c
          assign (at newAddr) (Just newContract)
          assign (ix newAddr . balance) (oldBal + xValue)
          assign (ix newAddr . nonce) 1
          modifying (ix self . balance) (flip (-) xValue)
          modifying (ix self . nonce) succ

        pushTrace (FrameTrace newContext)
        next
        vm1 <- get
        pushTo frames $ Frame
          { _frameContext = newContext
          , _frameState   = (set stack xs) (view state vm1)
          }

        assign state $
          blankState
            & set contract   newAddr
            & set codeContract newAddr
            & set code       initCode
            & set callvalue  xValue
            & set caller     self
            & set gas        xGas

-- | Replace a contract's code, like when CREATE returns
-- from the constructor code.
replaceCode :: Addr -> ContractCode -> EVM ()
replaceCode target newCode = do
  zoom (env . contracts . at target) $ do
    get >>= \case
      Just now -> case (view contractcode now) of
        InitCode _ ->
          put . Just $
          initialContract newCode
          & set storage (view storage now)
          & set balance (view balance now)
          & set nonce   (view nonce now)
        RuntimeCode _ ->
          error "internal error: can't replace code of deployed contract"
      Nothing ->
        error "internal error: can't replace code of nonexistent contract"

replaceCodeOfSelf :: ContractCode -> EVM ()
replaceCodeOfSelf newCode = do
  vm <- get
  replaceCode (view (state . contract) vm) newCode

resetState :: EVM ()
resetState = do
  assign result     Nothing
  assign frames     []
  assign state      blankState


-- * VM error implementation

vmError :: Error -> EVM ()
vmError e = finishFrame (FrameErrored e)

underrun :: EVM ()
underrun = vmError StackUnderrun

-- | A stack frame can be popped in three ways.
data FrameResult
  = FrameReturned [SWord 8] -- ^ STOP, RETURN, or no more code
  | FrameReverted [SWord 8] -- ^ REVERT
  | FrameErrored Error -- ^ Any other error
  deriving Show

-- | This function defines how to pop the current stack frame in either of
-- the ways specified by 'FrameResult'.
--
-- It also handles the case when the current stack frame is the only one;
-- in this case, we set the final '_result' of the VM execution.
finishFrame :: FrameResult -> EVM ()
finishFrame how = do
  oldVm <- get

  case view frames oldVm of
    -- Is the current frame the only one?
    [] -> do
      assign result . Just $
        case how of
          FrameReturned output -> VMSuccess output
          FrameReverted output -> VMFailure (Revert (forceLitBytes output))
          FrameErrored e       -> VMFailure e
      use execMode >>= \case
        ExecuteNormally ->
          noop
        _ -> do
          finalize

    -- Are there some remaining frames?
    nextFrame : remainingFrames -> do

      -- Pop the top frame.
      assign frames remainingFrames
      -- Install the state of the frame to which we shall return.
      assign state (view frameState nextFrame)
      -- Insert a debug trace.
      insertTrace $
        case how of
          FrameErrored e ->
            ErrorTrace e
          FrameReverted output ->
            ErrorTrace (Revert (forceLitBytes output))
          FrameReturned output ->
            ReturnTrace output (view frameContext nextFrame)
      -- Pop to the previous level of the debug trace stack.
      popTrace

      -- When entering a call, the gas allowance is counted as burned
      -- in advance; this unburns the remainder and adds it to the
      -- parent frame.
      let remainingGas = view (state . gas) oldVm
          reclaimRemainingGasAllowance = do
            modifying burned (subtract remainingGas)
            modifying (state . gas) (+ remainingGas)

          FeeSchedule {..} = view ( block . schedule ) oldVm

      -- Now dispatch on whether we were creating or calling,
      -- and whether we shall return, revert, or error (six cases).
      case view frameContext nextFrame of

        -- Were we calling?
        CallContext (num -> outOffset) (num -> outSize) _ _ _ reversion substate' -> do

          let
            revertContracts = assign (env . contracts) reversion
            revertSubstate  = assign (tx . substate) substate'

          case how of
            -- Case 1: Returning from a call?
            FrameReturned output -> do
              assign (state . returndata) output
              copyCallBytesToMemory output outSize 0 outOffset
              reclaimRemainingGasAllowance
              push 1

            -- Case 2: Reverting during a call?
            FrameReverted output -> do
              revertContracts
              revertSubstate
              assign (state . returndata) output
              copyCallBytesToMemory output outSize 0 outOffset
              reclaimRemainingGasAllowance
              push 0

            -- Case 3: Error during a call?
            FrameErrored _ -> do
              revertContracts
              revertSubstate
              assign (state . returndata) mempty
              push 0

        -- Or were we creating?
        CreationContext _ reversion substate' -> do
          creator <- use (state . contract)
          let
            createe = view (state . contract) oldVm
            revertContracts = assign (env . contracts) reversion'
            revertSubstate  = assign (tx . substate) substate'

            -- persist the nonce through the reversion
            reversion' = (Map.adjust (over nonce (+ 1)) creator) reversion

          case how of
            -- Case 4: Returning during a creation?
            FrameReturned output -> do
              replaceCode createe (RuntimeCode (forceLitBytes output))
              assign (state . returndata) mempty
              reclaimRemainingGasAllowance
              push (num createe)

            -- Case 5: Reverting during a creation?
            FrameReverted output -> do
              revertContracts
              revertSubstate
              assign (state . returndata) output
              reclaimRemainingGasAllowance
              push 0

            -- Case 6: Error during a creation?
            FrameErrored _ -> do
              revertContracts
              revertSubstate
              assign (state . returndata) mempty
              push 0


-- * Memory helpers

accessUnboundedMemoryRange
  :: FeeSchedule Word
  -> Word
  -> Word
  -> EVM ()
  -> EVM ()
accessUnboundedMemoryRange _ _ 0 continue = continue
accessUnboundedMemoryRange fees f l continue = do
  m0 <- num <$> use (state . memorySize)
  do
    let m1 = 32 * ceilDiv (max m0 (num(f) + num(l))) 32
    burn (memoryCost fees m1 - memoryCost fees m0) $ do
      assign (state . memorySize) (num m1)
      continue

accessMemoryRange
  :: FeeSchedule Word
  -> Word
  -> Word
  -> EVM ()
  -> EVM ()
accessMemoryRange _ _ 0 continue = continue
accessMemoryRange fees f l continue = do
  if f + l < l
    then vmError IllegalOverflow
    else do
      accessUnboundedMemoryRange fees f l continue

accessMemoryWord
  :: FeeSchedule Word -> Word -> EVM () -> EVM ()
accessMemoryWord fees x continue = accessMemoryRange fees x 32 continue

copyBytesToMemory
  :: [SWord 8] -> Word -> Word -> Word -> EVM ()
copyBytesToMemory bs size xOffset yOffset =
  if size == 0 then noop
  else do
    mem <- use (state . memory)
    assign (state . memory) $
      writeMemory bs size xOffset yOffset mem

copyCallBytesToMemory
  :: [SWord 8] -> Word -> Word -> Word -> EVM ()
copyCallBytesToMemory bs size xOffset yOffset =
  if size == 0 then noop
  else do
    mem <- use (state . memory)
    assign (state . memory) $
      writeMemory bs (min size (num (length bs))) xOffset yOffset mem

readMemory :: Word -> Word -> VM -> [SWord 8]
readMemory offset size vm = sliceWithZero (num offset) (num size) (view (state . memory) vm)

word256At
  :: Functor f
  => Word -> (SymWord -> f (SymWord))
  -> [SWord 8] -> f [SWord 8]
word256At i = lens getter setter where
  getter m = readMemoryWord i m
  setter m x = setMemoryWord i x m

-- * Tracing

withTraceLocation
  :: (MonadState VM m) => TraceData -> m Trace
withTraceLocation x = do
  vm <- get
  let
    Just this =
      preview (env . contracts . ix (view (state . codeContract) vm)) vm
  pure Trace
    { _traceData = x
    , _traceCodehash = view codehash this
    , _traceOpIx = (view opIxMap this) Vector.! (view (state . pc) vm)
    }

pushTrace :: TraceData -> EVM ()
pushTrace x = do
  trace <- withTraceLocation x
  modifying traces $
    \t -> Zipper.children $ Zipper.insert (Node trace []) t

insertTrace :: TraceData -> EVM ()
insertTrace x = do
  trace <- withTraceLocation x
  modifying traces $
    \t -> Zipper.nextSpace $ Zipper.insert (Node trace []) t

popTrace :: EVM ()
popTrace =
  modifying traces $
    \t -> case Zipper.parent t of
            Nothing -> error "internal error (trace root)"
            Just t' -> Zipper.nextSpace t'

zipperRootForest :: Zipper.TreePos Zipper.Empty a -> Forest a
zipperRootForest z =
  case Zipper.parent z of
    Nothing -> Zipper.toForest z
    Just z' -> zipperRootForest (Zipper.nextSpace z')

traceForest :: VM -> Forest Trace
traceForest vm =
  view (traces . to zipperRootForest) vm

traceLog :: (MonadState VM m) => Log -> m ()
traceLog log = do
  trace <- withTraceLocation (EventTrace log)
  modifying traces $
    \t -> Zipper.nextSpace (Zipper.insert (Node trace []) t)

-- * Stack manipulation

push :: Word -> EVM ()
push = pushSym . w256lit . num

pushSym :: SymWord -> EVM ()
pushSym x = state . stack %= (x :)


stackOp1
  :: (?op :: Word8)
  => ((SymWord) -> Word)
  -> ((SymWord) -> (SymWord))
  -> EVM ()
stackOp1 cost f =
  use (state . stack) >>= \case
    (x:xs) ->
      burn (cost x) $ do
        next
        let !y = f x
        state . stack .= y : xs
    _ ->
      underrun

stackOp2
  :: (?op :: Word8)
  => (((SymWord), (SymWord)) -> Word)
  -> (((SymWord), (SymWord)) -> (SymWord))
  -> EVM ()
stackOp2 cost f =
  use (state . stack) >>= \case
    (x:y:xs) ->
      burn (cost (x, y)) $ do
        next
        state . stack .= f (x, y) : xs
    _ ->
      underrun

stackOp3
  :: (?op :: Word8)
  => (((SymWord), (SymWord), (SymWord)) -> Word)
  -> (((SymWord), (SymWord), (SymWord)) -> (SymWord))
  -> EVM ()
stackOp3 cost f =
  use (state . stack) >>= \case
    (x:y:z:xs) ->
      burn (cost (x, y, z)) $ do
        next
        state . stack .= f (x, y, z) : xs
    _ ->
      underrun

-- * Bytecode data functions

checkJump :: (Integral n) => n -> [SymWord] -> EVM ()
checkJump x xs = do
  theCode <- use (state . code)
  self <- use (state . codeContract)
  theCodeOps <- use (env . contracts . ix self . codeOps)
  if x < num (BS.length theCode) && BS.index theCode (num x) == 0x5b
    then
      case RegularVector.find (\(i, op) -> i == num x && op == OpJumpdest) theCodeOps of
        Nothing ->  vmError BadJumpDestination
        _ -> do
             state . stack .= xs
             state . pc .= num x
    else vmError BadJumpDestination

opSize :: Word8 -> Int
opSize x | x >= 0x60 && x <= 0x7f = num x - 0x60 + 2
opSize _                          = 1

-- Index i of the resulting vector contains the operation index for
-- the program counter value i.  This is needed because source map
-- entries are per operation, not per byte.
mkOpIxMap :: ByteString -> Vector Int
mkOpIxMap xs = Vector.create $ Vector.new (BS.length xs) >>= \v ->
  -- Loop over the byte string accumulating a vector-mutating action.
  -- This is somewhat obfuscated, but should be fast.
  let (_, _, _, m) =
        BS.foldl' (go v) (0 :: Word8, 0, 0, return ()) xs
  in m >> return v
  where
    go v (0, !i, !j, !m) x | x >= 0x60 && x <= 0x7f =
      {- Start of PUSH op. -} (x - 0x60 + 1, i + 1, j,     m >> Vector.write v i j)
    go v (1, !i, !j, !m) _ =
      {- End of PUSH op. -}   (0,            i + 1, j + 1, m >> Vector.write v i j)
    go v (0, !i, !j, !m) _ =
      {- Other op. -}         (0,            i + 1, j + 1, m >> Vector.write v i j)
    go v (n, !i, !j, !m) _ =
      {- PUSH data. -}        (n - 1,        i + 1, j,     m >> Vector.write v i j)

vmOp :: VM -> Maybe Op
vmOp vm =
  let i  = vm ^. state . pc
      xs = BS.drop i (vm ^. state . code)
      op = BS.index xs 0
  in if BS.null xs
     then Nothing
     else Just (readOp op (BS.drop 1 xs))

vmOpIx :: VM -> Maybe Int
vmOpIx vm =
  do self <- currentContract vm
     (view opIxMap self) Vector.!? (view (state . pc) vm)

opParams :: VM -> Map String (SymWord)
opParams vm =
  case vmOp vm of
    Just OpCreate ->
      params $ words "value offset size"
    Just OpCall ->
      params $ words "gas to value in-offset in-size out-offset out-size"
    Just OpSstore ->
      params $ words "index value"
    Just OpCodecopy ->
      params $ words "mem-offset code-offset code-size"
    Just OpSha3 ->
      params $ words "offset size"
    Just OpCalldatacopy ->
      params $ words "to from size"
    Just OpExtcodecopy ->
      params $ words "account mem-offset code-offset code-size"
    Just OpReturn ->
      params $ words "offset size"
    Just OpJumpi ->
      params $ words "destination condition"
    _ -> mempty
  where
    params xs =
      if length (vm ^. state . stack) >= length xs
      then Map.fromList (zip xs (vm ^. state . stack))
      else mempty

readOp :: Word8 -> ByteString -> Op
readOp x _  | x >= 0x80 && x <= 0x8f = OpDup (x - 0x80 + 1)
readOp x _  | x >= 0x90 && x <= 0x9f = OpSwap (x - 0x90 + 1)
readOp x _  | x >= 0xa0 && x <= 0xa4 = OpLog (x - 0xa0)
readOp x xs | x >= 0x60 && x <= 0x7f =
  let n   = x - 0x60 + 1
      xs' = BS.take (num n) xs
  in OpPush (word xs')
readOp x _ = case x of
  0x00 -> OpStop
  0x01 -> OpAdd
  0x02 -> OpMul
  0x03 -> OpSub
  0x04 -> OpDiv
  0x05 -> OpSdiv
  0x06 -> OpMod
  0x07 -> OpSmod
  0x08 -> OpAddmod
  0x09 -> OpMulmod
  0x0a -> OpExp
  0x0b -> OpSignextend
  0x10 -> OpLt
  0x11 -> OpGt
  0x12 -> OpSlt
  0x13 -> OpSgt
  0x14 -> OpEq
  0x15 -> OpIszero
  0x16 -> OpAnd
  0x17 -> OpOr
  0x18 -> OpXor
  0x19 -> OpNot
  0x1a -> OpByte
  0x1b -> OpShl
  0x1c -> OpShr
  0x1d -> OpSar
  0x20 -> OpSha3
  0x30 -> OpAddress
  0x31 -> OpBalance
  0x32 -> OpOrigin
  0x33 -> OpCaller
  0x34 -> OpCallvalue
  0x35 -> OpCalldataload
  0x36 -> OpCalldatasize
  0x37 -> OpCalldatacopy
  0x38 -> OpCodesize
  0x39 -> OpCodecopy
  0x3a -> OpGasprice
  0x3b -> OpExtcodesize
  0x3c -> OpExtcodecopy
  0x3d -> OpReturndatasize
  0x3e -> OpReturndatacopy
  0x3f -> OpExtcodehash
  0x40 -> OpBlockhash
  0x41 -> OpCoinbase
  0x42 -> OpTimestamp
  0x43 -> OpNumber
  0x44 -> OpDifficulty
  0x45 -> OpGaslimit
  0x46 -> OpChainid
  0x47 -> OpSelfbalance
  0x50 -> OpPop
  0x51 -> OpMload
  0x52 -> OpMstore
  0x53 -> OpMstore8
  0x54 -> OpSload
  0x55 -> OpSstore
  0x56 -> OpJump
  0x57 -> OpJumpi
  0x58 -> OpPc
  0x59 -> OpMsize
  0x5a -> OpGas
  0x5b -> OpJumpdest
  0xf0 -> OpCreate
  0xf1 -> OpCall
  0xf2 -> OpCallcode
  0xf3 -> OpReturn
  0xf4 -> OpDelegatecall
  0xf5 -> OpCreate2
  0xfd -> OpRevert
  0xfa -> OpStaticcall
  0xff -> OpSelfdestruct
  _    -> (OpUnknown x)

mkCodeOps :: ByteString -> RegularVector.Vector (Int, Op)
mkCodeOps bytes = RegularVector.fromList . toList $ go 0 bytes
  where
    go !i !xs =
      case BS.uncons xs of
        Nothing ->
          mempty
        Just (x, xs') ->
          let j = opSize x
          in (i, readOp x xs') Seq.<| go (i + j) (BS.drop j xs)

-- * Gas cost calculation helpers

-- Gas cost function for CALL, transliterated from the Yellow Paper.
costOfCall
  :: FeeSchedule Word
  -> Bool -> Word -> Word -> Word
  -> (Word, Word)
costOfCall (FeeSchedule {..}) recipientExists xValue availableGas xGas =
  (c_gascap + c_extra, c_callgas)
  where
    c_extra =
      num g_call + c_xfer + c_new
    c_xfer =
      if xValue /= 0          then num g_callvalue              else 0
    c_callgas =
      if xValue /= 0          then c_gascap + num g_callstipend else c_gascap
    c_new =
      if not recipientExists && xValue /= 0
      then num g_newaccount
      else 0
    c_gascap =
      if availableGas >= c_extra
      then min xGas (allButOne64th (availableGas - c_extra))
      else xGas

-- Gas cost of create, including hash cost if needed
costOfCreate
  :: FeeSchedule Word
  -> Word -> Word -> (Word, Word)
costOfCreate (FeeSchedule {..}) availableGas hashSize =
  (createCost + initGas, initGas)
  where
    createCost = g_create + hashCost
    hashCost   = g_sha3word * ceilDiv (hashSize) 32
    initGas    = allButOne64th (availableGas - createCost)

-- Gas cost of precompiles
costOfPrecompile :: FeeSchedule Word -> Addr -> ByteString -> Word
costOfPrecompile (FeeSchedule {..}) precompileAddr input =
  case precompileAddr of
    -- ECRECOVER
    0x1 -> 3000
    -- SHA2-256
    0x2 -> num $ (((BS.length input + 31) `div` 32) * 12) + 60
    -- RIPEMD-160
    0x3 -> num $ (((BS.length input + 31) `div` 32) * 120) + 600
    -- IDENTITY
    0x4 -> num $ (((BS.length input + 31) `div` 32) * 3) + 15
    -- MODEXP
    0x5 -> num $ (f (num (max lenm lenb)) * num (max lene' 1)) `div` (num g_quaddivisor)
      where (lenb, lene, lenm) = parseModexpLength input
            lene' = if lene <= 32 && ez then 0
                    else if lene <= 32 then num (log2 e')
                    else if e' == 0 then 8 * (lene - 32)
                    else num (log2 e') + 8 * (lene - 32)

            ez = isZero (96 + lenb) lene input
            e' = w256 $ word $ LS.toStrict $
                   lazySlice (96 + lenb) (min 32 lene) input

            f :: Integer -> Integer
            f x = if x <= 64 then x * x
                  else if x <= 1024
                  then (x * x) `div` 4 + 96 * x - 3072
                  else (x * x) `div` 16 + 480 * x - 199680
    -- ECADD
    0x6 -> g_ecadd
    -- ECMUL
    0x7 -> g_ecmul
    -- ECPAIRING
    0x8 -> num $ ((BS.length input) `div` 192) * (num g_pairing_point) + (num g_pairing_base)
    -- BLAKE2
    0x9 -> g_fround * (num $ asInteger $ lazySlice 0 4 input)
    _ -> error ("unimplemented precompiled contract " ++ show precompileAddr)

-- Gas cost of memory expansion
memoryCost :: FeeSchedule Word -> Word -> Word
memoryCost FeeSchedule{..} byteCount =
  let
    wordCount = ceilDiv byteCount 32
    linearCost = g_memory * wordCount
    quadraticCost = div (wordCount * wordCount) 512
  in
    linearCost + quadraticCost

-- * Symbolic versions



-- symKeccak :: (KnownNat n, IsNonZero n) => Proxy n -> SWord n -> SymWord
-- symKeccak _ = uninterpret "keccak" 


-- * Arithmetic

ceilDiv :: (Num a, Integral a) => a -> a -> a
ceilDiv m n = div (m + n - 1) n

allButOne64th :: (Num a, Integral a) => a -> a
allButOne64th n = n - div n 64

log2 :: FiniteBits b => b -> Int
log2 x = finiteBitSize x - 1 - countLeadingZeros x


-- * Emacs setup

-- Local Variables:
-- outline-regexp: "-- \\*+\\|data \\|newtype \\|type \\| +-- op: "
-- outline-heading-alist:
--   (("-- *" . 1) ("data " . 2) ("newtype " . 2) ("type " . 2))
-- compile-command: "make"
-- End:

