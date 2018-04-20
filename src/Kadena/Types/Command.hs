{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kadena.Types.Command
  ( Command(..), sccCmd, sccPreProc, cccCmd, cccPreProc, pcCmd
  , Hashed(..)
  , encodeCommand, decodeCommand, decodeCommandEither
  , {- decodeCommandIO, -} decodeCommandEitherIO
  , verifyCommand, verifyCommandIfNotPending
  , prepPreprocCommand
  , Preprocessed(..), RunPreProc(..), runPreproc, runPreprocPure
  , FinishedPreProc(..), finishPreProc
  , PendingResult(..)
  , getCmdBodyHash
  , SCCPreProcResult, CCCPreProcResult
  , CMDWire(..)
  , toRequestKey
  , CommandResult(..), scrResult, crHash, crLogIndex, crLatMetrics, ccrResult, cprResult
  , CmdLatencyMetrics(..), lmFirstSeen, lmHitTurbine, lmHitPreProc, lmAerConsensus, lmLogConsensus
  , lmFinPreProc, lmHitExecution, lmFinExecution, lmHitConsensus, lmFinConsensus
  , initCmdLat, populateCmdLat
  , CmdLatASetter
  , CmdResultLatencyMetrics(..)
  , rlmFirstSeen, rlmHitTurbine, rlmHitConsensus, rlmFinConsensus, rlmAerConsensus, rlmLogConsensus
  , rlmHitPreProc, rlmFinPreProc, rlmHitExecution, rlmFinExecution
  , mkLatResults
  ) where

import Control.Exception
import Control.Lens
import Control.Monad
import Control.Concurrent
import Control.DeepSeq

import Data.Serialize (Serialize)
import qualified Data.Serialize as S
import Data.ByteString (ByteString)

import Data.Thyme.Clock
import Data.Thyme.Time.Core ()
import Data.Aeson
import GHC.Generics
import GHC.Int (Int64)

import Kadena.Types.Base
import Kadena.Types.Config
import Kadena.Types.Message.Signed
import Kadena.Private.Types (PrivateCiphertext,PrivateResult)

import qualified Pact.Types.Command as Pact
import qualified Pact.Types.RPC as Pact
import Pact.Types.Util

data CmdLatencyMetrics = CmdLatencyMetrics
  { _lmFirstSeen :: !UTCTime
  , _lmHitTurbine :: !(Maybe UTCTime)
  , _lmHitConsensus :: !(Maybe UTCTime)
  , _lmFinConsensus :: !(Maybe UTCTime)
  , _lmAerConsensus :: !(Maybe UTCTime)
  , _lmLogConsensus :: !(Maybe UTCTime)
  , _lmHitPreProc :: !(Maybe UTCTime)
  , _lmFinPreProc :: !(Maybe UTCTime)
  , _lmHitExecution :: !(Maybe UTCTime)
  , _lmFinExecution :: !(Maybe UTCTime)
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''CmdLatencyMetrics

instance ToJSON CmdLatencyMetrics where
  toJSON = lensyToJSON 3
instance FromJSON CmdLatencyMetrics where
  parseJSON = lensyParseJSON 3

initCmdLat :: Maybe ReceivedAt -> Maybe CmdLatencyMetrics
initCmdLat Nothing = Nothing
initCmdLat (Just (ReceivedAt startTime)) = Just $ CmdLatencyMetrics
  { _lmFirstSeen = startTime
  , _lmHitTurbine = Nothing
  , _lmHitConsensus = Nothing
  , _lmFinConsensus = Nothing
  , _lmAerConsensus = Nothing
  , _lmLogConsensus = Nothing
  , _lmHitPreProc = Nothing
  , _lmFinPreProc = Nothing
  , _lmHitExecution = Nothing
  , _lmFinExecution = Nothing
  }

type CmdLatASetter a = ASetter CmdLatencyMetrics CmdLatencyMetrics a (Maybe UTCTime)

populateCmdLat ::
  CmdLatASetter a
  -> UTCTime
  -> Maybe CmdLatencyMetrics
  -> Maybe CmdLatencyMetrics
populateCmdLat l t = fmap (over l (\_ -> Just t))
{-# INLINE populateCmdLat #-}

data PendingResult a = PendingResult
  { _prResult :: !a
  , _prStartedPreProc :: !(Maybe UTCTime)
  , _prFinishedPreProc :: !(Maybe UTCTime)
  }

data Preprocessed a =
  Unprocessed |
  Pending {pending :: !(MVar (PendingResult a))} |
  Result {result :: a}
  deriving (Eq, Generic)
instance (Show a) => Show (Preprocessed a) where
  show Unprocessed = "Unprocessed"
  show Pending{} = "Pending {unPending = <MVar>}"
  show (Result a) = "Result {unResult = " ++ show a ++ "}"

type SCCPreProcResult = PendingResult (Pact.ProcessedCommand (Pact.PactRPC Pact.ParsedCode))
type CCCPreProcResult = PendingResult ProcessedConfigUpdate

data RunPreProc =
  RunSCCPreProc
    { _rpSccRaw :: !(Pact.Command ByteString)
    , _rpSccMVar :: !(MVar SCCPreProcResult) } |
  RunCCCPreProc
    { _rpCccRaw :: !(ConfigUpdate ByteString)
    , _rpCccMVar :: !(MVar CCCPreProcResult) }

data FinishedPreProc =
  FinishedPreProcSCC
    { _fppSccRes :: !(Pact.ProcessedCommand (Pact.PactRPC Pact.ParsedCode))
    , _fppSccMVar :: !(MVar SCCPreProcResult)} |
  FinishedPreProcCCC
    { _fppCccRes :: !ProcessedConfigUpdate
    , _fppCccMVar :: !(MVar CCCPreProcResult)}

instance NFData FinishedPreProc where
  rnf FinishedPreProcSCC{..} = case _fppSccRes of
    Pact.ProcSucc s -> rnf s
    Pact.ProcFail e -> rnf e
  rnf FinishedPreProcCCC{..} = case _fppCccRes of
    ProcessedConfigSuccess s _ -> s `seq` ()
    ProcessedConfigFailure e -> rnf e

runPreprocPure :: RunPreProc -> FinishedPreProc
runPreprocPure RunSCCPreProc{..} =
  let !res = Pact.verifyCommand _rpSccRaw
  in res `seq` FinishedPreProcSCC res _rpSccMVar
runPreprocPure RunCCCPreProc{..} =
  let !res = processConfigUpdate _rpCccRaw
  in res `seq` FinishedPreProcCCC res _rpCccMVar
{-# INLINE runPreprocPure #-}

finishPreProc :: UTCTime -> UTCTime -> FinishedPreProc -> IO ()
finishPreProc startTime endTime FinishedPreProcSCC{..} = do
  succPut <- tryPutMVar _fppSccMVar $! PendingResult _fppSccRes (Just startTime) (Just endTime)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _fppSccRes
finishPreProc startTime endTime FinishedPreProcCCC{..} = do
  succPut <- tryPutMVar _fppCccMVar $! PendingResult _fppCccRes (Just startTime) (Just endTime)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _fppCccRes
{-# INLINE finishPreProc #-}

runPreproc :: UTCTime -> RunPreProc -> IO ()
runPreproc hitPreProc RunSCCPreProc{..} = do
  res <- return $! Pact.verifyCommand _rpSccRaw
  finishedPreProc <- getCurrentTime
  succPut <- tryPutMVar _rpSccMVar $! PendingResult res (Just hitPreProc) (Just finishedPreProc)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _rpSccRaw
runPreproc hitPreProc RunCCCPreProc{..} = do
  res <- return $! processConfigUpdate _rpCccRaw
  finishedPreProc <- getCurrentTime
  succPut <- tryPutMVar _rpCccMVar $! PendingResult res (Just hitPreProc) (Just finishedPreProc)
  unless succPut $ putStrLn $ "Preprocessor encountered a duplicate: " ++ show _rpCccRaw
{-# INLINE runPreproc #-}

data Hashed a = Hashed
  { _hValue :: !a
  , _hHash :: !Hash
  } deriving (Show,Eq,Generic)
instance Serialize a => Serialize (Hashed a)
instance NFData a => NFData (Hashed a)

data Command =
  SmartContractCommand
  { _sccCmd :: !(Pact.Command ByteString)
  , _sccPreProc :: !(Preprocessed (Pact.ProcessedCommand (Pact.PactRPC Pact.ParsedCode))) } |
  ConsensusConfigCommand
  { _cccCmd :: !(ConfigUpdate ByteString)
  , _cccPreProc :: !(Preprocessed ProcessedConfigUpdate)} |
  PrivateCommand
  { _pcCmd :: !(Hashed PrivateCiphertext)
  }
  deriving (Show, Eq, Generic)
makeLenses ''Command

instance Ord Command where
  compare a b = compare (getCmdBodyHash a) (getCmdBodyHash b)

data CMDWire =
  SCCWire !ByteString |
  CCCWire !ByteString |
  PCWire !ByteString
  deriving (Show, Eq, Generic)
instance Serialize CMDWire

encodeCommand :: Command -> CMDWire
encodeCommand SmartContractCommand{..} = SCCWire $! S.encode _sccCmd
encodeCommand ConsensusConfigCommand{..} = CCCWire $! S.encode _cccCmd
encodeCommand PrivateCommand{..} = PCWire $! S.encode _pcCmd
{-# INLINE encodeCommand #-}

-- | Decode that throws `DeserializationError`
decodeCommand :: CMDWire -> Command
decodeCommand (SCCWire !b) =
  let
    !cmd = case S.decode b of
      Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right v -> v
    !res = SmartContractCommand cmd Unprocessed
  in res `seq` res
decodeCommand (CCCWire !b) =
  let
    !cmd = case S.decode b of
      Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right v -> v
    !res = ConsensusConfigCommand cmd Unprocessed
  in res `seq` res
decodeCommand (PCWire !b) =
  let
    !cmd = case S.decode b of
      Left err -> throw $ DeserializationError $ err ++ "\n### for ###\n" ++ show b
      Right v -> v
    !res = PrivateCommand cmd
  in res `seq` res
{-# INLINE decodeCommand #-}

decodeCommandEither :: CMDWire -> Either String Command
decodeCommandEither (SCCWire !b) = case S.decode b of
  Left !err -> Left $! err ++ "\n### for ###\n" ++ show b
  Right !cmd -> Right $! (SmartContractCommand cmd Unprocessed)
decodeCommandEither (CCCWire !b) = case S.decode b of
  Left !err -> Left $! err ++ "\n### for ###\n" ++ show b
  Right !cmd -> Right $! (ConsensusConfigCommand cmd Unprocessed)
decodeCommandEither (PCWire !b) = case S.decode b of
  Left !err -> Left $! err ++ "\n### for ###\n" ++ show b
  Right !cmd -> Right $! (PrivateCommand cmd)
{-# INLINE decodeCommandEither #-}

{-
decodeCommandIO :: CMDWire -> IO (Command, RunPreProc)
decodeCommandIO cmd = case decodeCommand cmd of
  r@SmartContractCommand{..} -> do
    mv <- newEmptyMVar
    let rpp = RunSCCPreProc _sccCmd mv
    return $! (r { _sccPreProc = Pending mv }, rpp)
  r@ConsensusConfigCommand{..} -> do
    mv <- newEmptyMVar
    let rpp = RunCCCPreProc _cccCmd mv
    return $! (r { _cccPreProc = Pending mv }, rpp)
-}

decodeCommandEitherIO :: CMDWire -> IO (Either String (Command, Maybe RunPreProc))
decodeCommandEitherIO cmd = case decodeCommandEither cmd of
  Left err -> return $ Left $ err ++ "\n### for ###\n" ++ show cmd
  Right v -> case v of
    r@SmartContractCommand{..} -> do
      mv <- newEmptyMVar
      let rpp = RunSCCPreProc _sccCmd mv
      return $ Right $! (r { _sccPreProc = Pending mv }, Just rpp)
    r@ConsensusConfigCommand{..} -> do
      mv <- newEmptyMVar
      let rpp = RunCCCPreProc _cccCmd mv
      return $! Right $! (r { _cccPreProc = Pending mv }, Just rpp)
    r@PrivateCommand{} -> return $! Right (r,Nothing)

prepPreprocCommand :: Command -> IO (Command, Maybe RunPreProc)
prepPreprocCommand cmd@SmartContractCommand{..} = do
  case _sccPreProc of
    Unprocessed -> do
      mv <- newEmptyMVar
      return $ (cmd { _sccPreProc = Pending mv}, Just $ RunSCCPreProc _sccCmd mv)
    err -> error $ "Invariant Error: cmd has already been preped: " ++ show err ++ "\n### for ###\n" ++ show _sccCmd
prepPreprocCommand cmd@ConsensusConfigCommand{..} = do
  case _cccPreProc of
    Unprocessed -> do
      mv <- newEmptyMVar
      return $ (cmd { _cccPreProc = Pending mv}, Just $ RunCCCPreProc _cccCmd mv)
    err -> error $ "Invariant Error: cmd has already been preped: " ++ show err ++ "\n### for ###\n" ++ show _cccCmd
prepPreprocCommand c@PrivateCommand{} = return $! (c,Nothing)

verifyCommandIfNotPending :: Command -> Command
verifyCommandIfNotPending cmd@SmartContractCommand{..} =
  let res = case _sccPreProc of
              Unprocessed -> verifyCommand cmd
              Pending{} -> cmd
              Result{} -> cmd
  in res `seq` res
verifyCommandIfNotPending cmd@ConsensusConfigCommand{..} =
  let res = case _cccPreProc of
              Unprocessed -> verifyCommand cmd
              Pending{} -> cmd
              Result{} -> cmd
  in res `seq` res
verifyCommandIfNotPending cmd@PrivateCommand{} = cmd
{-# INLINE verifyCommandIfNotPending #-}

verifyCommand :: Command -> Command
verifyCommand cmd@SmartContractCommand{..} =
  let !res = Result $! Pact.verifyCommand _sccCmd
  in res `seq` cmd { _sccPreProc = res }
verifyCommand cmd@ConsensusConfigCommand{..} =
  let !res = Result $! processConfigUpdate _cccCmd
  in res `seq` cmd { _cccPreProc = res }
verifyCommand cmd@PrivateCommand{} = cmd
{-# INLINE verifyCommand #-}

getCmdBodyHash :: Command -> Hash
getCmdBodyHash SmartContractCommand{ _sccCmd = Pact.Command{..}} = _cmdHash
getCmdBodyHash ConsensusConfigCommand{ _cccCmd = ConfigUpdate{..}} = _cuHash
getCmdBodyHash PrivateCommand { _pcCmd = Hashed{..}} = _hHash

toRequestKey :: Command -> RequestKey
toRequestKey = RequestKey . getCmdBodyHash
{-# INLINE toRequestKey #-}

data CmdResultLatencyMetrics = CmdResultLatencyMetrics
  { _rlmFirstSeen :: !UTCTime
  , _rlmHitTurbine :: !(Maybe Int64)
  , _rlmHitConsensus :: !(Maybe Int64)
  , _rlmFinConsensus :: !(Maybe Int64)
  , _rlmAerConsensus :: !(Maybe Int64)
  , _rlmLogConsensus :: !(Maybe Int64)
  , _rlmHitPreProc :: !(Maybe Int64)
  , _rlmFinPreProc :: !(Maybe Int64)
  , _rlmHitExecution :: !(Maybe Int64)
  , _rlmFinExecution :: !(Maybe Int64)
  } deriving (Show, Eq, Ord, Generic)
makeLenses ''CmdResultLatencyMetrics

instance ToJSON CmdResultLatencyMetrics where
  toJSON = lensyToJSON 4
instance FromJSON CmdResultLatencyMetrics where
  parseJSON = lensyParseJSON 4

mkLatResults :: CmdLatencyMetrics -> CmdResultLatencyMetrics
mkLatResults CmdLatencyMetrics{..} = CmdResultLatencyMetrics
  { _rlmFirstSeen = _lmFirstSeen
  , _rlmHitTurbine = interval _lmFirstSeen <$> _lmHitTurbine
  , _rlmHitConsensus = interval _lmFirstSeen <$> _lmHitConsensus
  , _rlmFinConsensus = interval _lmFirstSeen <$> _lmFinConsensus
  , _rlmAerConsensus = interval _lmFirstSeen <$> _lmAerConsensus
  , _rlmLogConsensus = interval _lmFirstSeen <$> _lmLogConsensus
  , _rlmHitPreProc = interval _lmFirstSeen <$> _lmHitPreProc
  , _rlmFinPreProc = interval _lmFirstSeen <$> _lmFinPreProc
  , _rlmHitExecution = interval _lmFirstSeen <$> _lmHitExecution
  , _rlmFinExecution = interval _lmFirstSeen <$> _lmFinExecution
  }

data CommandResult =
  SmartContractResult
    { _crHash :: !Hash
    , _scrResult :: !Pact.CommandResult
    , _crLogIndex :: !LogIndex
    , _crLatMetrics :: !(Maybe CmdResultLatencyMetrics) } |
  ConsensusConfigResult
    { _crHash :: !Hash
    , _ccrResult :: !ConfigUpdateResult
    , _crLogIndex :: !LogIndex
    , _crLatMetrics :: !(Maybe CmdResultLatencyMetrics) } |
  PrivateCommandResult
    { _crHash :: !Hash
    , _cprResult :: !(PrivateResult Pact.CommandResult)
    , _crLogIndex :: !LogIndex
    , _crLatMetrics :: !(Maybe CmdResultLatencyMetrics) }
  deriving (Show, Eq, Generic)
makeLenses ''CommandResult
