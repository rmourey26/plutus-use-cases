{-# LANGUAGE DataKinds          #-}
{-# LANGUAGE DeriveAnyClass     #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts   #-}
{-# LANGUAGE LambdaCase         #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE TypeApplications   #-}
{-# LANGUAGE TypeFamilies       #-}
{-# LANGUAGE TypeOperators      #-}

module Main(main) where

import           Control.Monad                       (void, forM)
import           Control.Monad.Freer                 (Eff, Member, interpret, type (~>))
import qualified Control.Concurrent.STM                         as STM
import           Control.Monad.Freer.Error           (Error)
import           Control.Monad.Freer.Extras.Log          (LogMsg)
import           Control.Monad.IO.Class              (MonadIO (..))
import qualified Data.Monoid                             as Monoid
import qualified Data.Map.Strict                         as Map
import           Data.Text                        (Text, pack)
import qualified Data.Text               as T
import qualified Data.ByteString.Char8        as C
import           Data.Aeson                          (FromJSON (..), Result (..), ToJSON (..), genericToJSON, genericParseJSON
                                                     , defaultOptions, Options(..), decode, encode, parseJSON, fromJSON)
import           Data.Text.Prettyprint.Doc           (Pretty (..), viaShow)
import           GHC.Generics                        (Generic)
import           Plutus.Contract                     (BlockchainActions, ContractError)
import           Plutus.PAB.Effects.Contract         (ContractEffect (..))
import           Plutus.PAB.Effects.Contract.Builtin (Builtin, SomeBuiltin (..), type (.\\))
import qualified Plutus.PAB.Effects.Contract.Builtin as Builtin
import           Plutus.PAB.Simulator                (SimulatorEffectHandlers)
import qualified Plutus.PAB.Simulator                as Simulator
import           Plutus.PAB.Types                    (PABError (..))
import qualified Plutus.PAB.Webserver.Server         as PAB.Server
import           Contracts.NFT                       as NFTMarket
import           Wallet.Emulator.Types               (Wallet (..))
import qualified Data.ByteString.Char8               as B
import qualified Ledger.Value            as Value
import           Ledger.Value                        (TokenName (..), Value)
import           Wallet.API                               (ownPubKey)
import           Ledger                                   (CurrencySymbol(..), pubKeyAddress)
import qualified Ledger.Typed.Scripts         as Scripts
import           Plutus.PAB.Monitoring.PABLogMsg         (PABMultiAgentMsg)

extract :: Maybe a -> a
extract (Just x) = x          -- Sure, this works, but...
extract Nothing  = undefined 

main :: IO ()
main = void $ Simulator.runSimulationWith handlers $ do
    Simulator.logString @(Builtin NFTMarketContracts) "Starting nft market place PAB webserver on port 8080. Press enter to exit."
    shutdown <- PAB.Server.startServerDebug

    let w1 = Wallet 1
    w1Address <- pubKeyAddress <$> Simulator.handleAgentThread w1 ownPubKey

    nftMarketInstance1 <- Simulator.activateContract w1 NFTStartContract
    market       <- flip Simulator.waitForState nftMarketInstance1 $ \json -> case (fromJSON json :: Result (Monoid.Last (Either Text NFTMarket.NFTMarket))) of
                    Success (Monoid.Last (Just (Right market))) -> Just market
                    _                                             -> Nothing

    Simulator.logString @(Builtin NFTMarketContracts) $ "NFT Marketplace instance created: " ++ show market


    cids <- fmap Map.fromList $ forM wallets $ \w -> do
        cid <- Simulator.activateContract w $ NFTUserContract market
        Simulator.logString @(Builtin NFTMarketContracts) $ "NFT user contract started for " ++ show w
        _ <- Simulator.callEndpointOnInstance cid "funds" ()
        v <- flip Simulator.waitForState cid $ \json -> case (fromJSON json :: Result (Monoid.Last (Either Text NFTMarket.MarketContractState))) of
                Success (Monoid.Last (Just (Right (NFTMarket.Funds v)))) -> Just v
                _                                                      -> Nothing
        Simulator.logString @(Builtin NFTMarketContracts) $ "initial funds in wallet " ++ show w ++ ": " ++ show v
        return (w, cid)

    let nftTokenParams = NFTMarket.CreateParams { cpTokenName = "TestToken", cpDescription = C.pack "TestDescrition"}
    Simulator.logString @(Builtin NFTMarketContracts) $ "nft token create params: " ++ show (encode nftTokenParams)
    void $ Simulator.callEndpointOnInstance (cids Map.! Wallet 2) "create" nftTokenParams
    _ <- flip Simulator.waitForState (cids Map.! Wallet 2) $ \json -> case (fromJSON json :: Result (Monoid.Last (Either Text NFTMarket.MarketContractState))) of
        Success (Monoid.Last (Just (Right NFTMarket.Created))) -> Just ()
        _                                                      -> Nothing
    Simulator.logString @(Builtin NFTMarketContracts) "NFT token created"
    Simulator.waitNSlots 1
    ------------
    void $ liftIO getLine
    
    Simulator.logString @(Builtin NFTMarketContracts) "Balances at the end of the simulation"
    b <- Simulator.currentBalances
    Simulator.logBalances @(Builtin NFTMarketContracts) b

    shutdown

data NFTMarketContracts =
      NFTStartContract 
    | NFTUserContract NFTMarket.NFTMarket
    deriving (Eq, Ord, Show, Generic)

instance ToJSON NFTMarketContracts where
  toJSON = genericToJSON defaultOptions {
             tagSingleConstructors = True }
instance FromJSON NFTMarketContracts where
  parseJSON = genericParseJSON defaultOptions {
             tagSingleConstructors = True }

instance Pretty NFTMarketContracts where
    pretty = viaShow

handleNFTMarketContract ::
    ( Member (Error PABError) effs
    , Member (LogMsg (PABMultiAgentMsg (Builtin NFTMarketContracts))) effs
    )
    => ContractEffect (Builtin NFTMarketContracts)
    ~> Eff effs
handleNFTMarketContract = Builtin.handleBuiltin getSchema getContract where
    getSchema = \case
        NFTStartContract -> Builtin.endpointsToSchemas @(NFTMarket.MarketOwnerSchema .\\ BlockchainActions)
        NFTUserContract _  -> Builtin.endpointsToSchemas @(NFTMarket.MarketUserSchema .\\ BlockchainActions)
    getContract = \case
        NFTStartContract -> SomeBuiltin NFTMarket.ownerEndpoint
        NFTUserContract market -> SomeBuiltin $ NFTMarket.userEndpoints market

handlers :: SimulatorEffectHandlers (Builtin NFTMarketContracts)
handlers =
    Simulator.mkSimulatorHandlers @(Builtin NFTMarketContracts)[] --[NFTStartContract, NFTUserContract]
    $ interpret handleNFTMarketContract

wallets :: [Wallet]
wallets = [Wallet i | i <- [1 .. 4]]