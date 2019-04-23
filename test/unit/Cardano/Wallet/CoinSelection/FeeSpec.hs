{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Cardano.Wallet.CoinSelection.FeeSpec
    ( spec
    ) where

import Prelude

import Cardano.Wallet.CoinSelection
    ( CoinSelection (..), CoinSelectionOptions (..) )
import Cardano.Wallet.CoinSelection.Fee
    ( Fee (..), FeeError (..), FeeOptions (..), adjustForFees )
import Cardano.Wallet.CoinSelection.Policy.LargestFirst
    ( largestFirst )
import Cardano.Wallet.CoinSelectionSpec
    ( CoinSelProp (..), genTxOut, genUTxO )
import Cardano.Wallet.Primitive.Types
    ( Coin (..), ShowFmt (..), TxOut (..), UTxO (..) )
import Control.Arrow
    ( left )
import Control.Monad.Trans.Except
    ( runExceptT )
import Crypto.Random
    ( SystemDRG, getSystemDRG )
import Crypto.Random.Types
    ( withDRG )
import Data.Either
    ( isRight )
import Data.Functor.Identity
    ( Identity (runIdentity) )
import Data.Word
    ( Word64 )
import Fmt
    ( Buildable (..), nameF, tupleF )
import Test.Hspec
    ( Spec, SpecWith, before, describe, it, shouldBe, shouldSatisfy )
import Test.QuickCheck
    ( Arbitrary (..), Property, choose, disjoin, generate, property, (==>) )

import qualified Data.Map.Strict as Map


spec :: Spec
spec = do
    describe "Fee calculation : unit tests" $ do
        -- Change covers fee exactly, single change output
        feeUnitTest (FeeFixture
            { fInps = [20]
            , fOuts = [17]
            , fChngs = [3]
            , fUtxo = []
            , fFee = 3
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [20]
            , csOuts = [17]
            , csChngs = []
            })

        -- Total change covers fee, multiple change outputs
        feeUnitTest (FeeFixture
            { fInps = [20,20]
            , fOuts = [16,18]
            , fChngs = [4,2]
            , fUtxo = []
            , fFee = 6
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [20,20]
            , csOuts = [16,18]
            , csChngs = []
            })

        -- Fee split evenly across change outputs
        feeUnitTest (FeeFixture
            { fInps = [20,20]
            , fOuts = [18,18]
            , fChngs = [2,2]
            , fUtxo = []
            , fFee = 2
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [20,20]
            , csOuts = [18,18]
            , csChngs = [1,1]
            })

        -- Fee split evenly across change outputs, with rounding 'issues'
        feeUnitTest (FeeFixture
            { fInps = [20,20]
            , fOuts = [17,18]
            , fChngs = [3,2]
            , fUtxo = []
            , fFee = 2
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [20,20]
            , csOuts = [17,18]
            , csChngs = [1,1]
            })

        -- Fee divvied, dust removed (dust = 0)
        feeUnitTest (FeeFixture
            { fInps = [20,20,20]
            , fOuts = [14,18,19]
            , fChngs = [6,2,1]
            , fUtxo = []
            , fFee = 3
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [20,20,20]
            , csOuts = [14,18,19]
            , csChngs = [4,1]
            })

        -- Fee divvied, dust removed (dust = 1)
        feeUnitTest (FeeFixture
            { fInps = [20,20,20]
            , fOuts = [14,18,19]
            , fChngs = [6,2,1]
            , fUtxo = []
            , fFee = 3
            , fDust = 1
            }) (Right $ FeeOutput
            { csInps = [20,20,20]
            , csOuts = [14,18,19]
            , csChngs = [4]
            })

        -- Cannot cover fee, no extra inputs
        feeUnitTest (FeeFixture
            { fInps = [20]
            , fOuts = [17]
            , fChngs = [3]
            , fUtxo = []
            , fFee = 4
            , fDust = 0
            }) (Left $ CannotCoverFee 1)

        -- Cannot cover fee even with an extra (too small) inputs
        feeUnitTest (FeeFixture
            { fInps = [10]
            , fOuts = [7]
            , fChngs = [3]
            , fUtxo = [1]
            , fFee = 5
            , fDust = 0
            }) (Left $ CannotCoverFee 1)

        -- Can select extra inputs to exactly cover fee, no change back
        feeUnitTest (FeeFixture
            { fInps = [10]
            , fOuts = [7]
            , fChngs = [3]
            , fUtxo = [1,1]
            , fFee = 5
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [10,1,1]
            , csOuts = [7]
            , csChngs = []
            })

        -- Can select extra inputs to cover for fee, and leave a change back
        feeUnitTest (FeeFixture
            { fInps = [10]
            , fOuts = [7]
            , fChngs = [3]
            , fUtxo = [3]
            , fFee = 5
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [10,3]
            , csOuts = [7]
            , csChngs = [1]
            })

        -- Multiple change output, can select extra inputs to cover fee, no change
        feeUnitTest (FeeFixture
            { fInps = [10,10]
            , fOuts = [7,7]
            , fChngs = [3,3]
            , fUtxo = [2,2]
            , fFee = 9
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [10,10,2,2]
            , csOuts = [7,7]
            , csChngs = []
            })

        -- Multiple outputs, extra inputs selected, resulting change
        feeUnitTest (FeeFixture
            { fInps = [10,10]
            , fOuts = [7,7]
            , fChngs = [3,3]
            , fUtxo = [3,3]
            , fFee = 10
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [10,10,3,3]
            , csOuts = [7,7]
            , csChngs = [1,1]
            })

        -- Multiple change outputs, some bigger than actual Dust
        feeUnitTest (FeeFixture
            { fInps = [20,20]
            , fOuts = [16,18]
            , fChngs = [4,2]
            , fUtxo = []
            , fFee = 6
            , fDust = 2
            }) (Right $ FeeOutput
            { csInps = [20,20]
            , csOuts = [16,18]
            , csChngs = []
            })

        -- Selection with no fee
        feeUnitTest (FeeFixture
            { fInps = [10,10]
            , fOuts = [7,7]
            , fChngs = [3,3]
            , fUtxo = [3,3]
            , fFee = 0
            , fDust = 0
            }) (Right $ FeeOutput
            { csInps = [10,10]
            , csOuts = [7,7]
            , csChngs = [3,3]
            })

    before getSystemDRG $ describe "Fee calculation properties" $ do
        it "No fee gives back the same selection"
            (\_ -> property propSameSelection)
        it "Fee adjustment is deterministic when there's no extra inputs"
            (\_ -> property propDeterministic)
        it "Adjusting for fee (/= 0) reduces the change outputs or increase inputs"
            (property . propReducedChanges)

{-------------------------------------------------------------------------------
                         Fee Adjustment - Properties
-------------------------------------------------------------------------------}

-- | Data for running fee calculation properties
data FeeProp = FeeProp
    { coveringCase :: CoinSelProp
     -- ^ inputs from wich largestFirst can be calculated
    , availableUtxo :: UTxO
     -- ^ additional UTxO from which fee calculation will pick needed coins
    , feeDust :: (Word64, Word64)
     -- ^ constant fee and dust threshold
    } deriving Show

instance Buildable FeeProp where
    build (FeeProp cc utxo opt) = mempty
        <> nameF "selection" (build cc)
        <> build utxo
        <> nameF "options" (tupleF opt)

propSameSelection
    :: ShowFmt FeeProp
    -> Property
propSameSelection (ShowFmt (FeeProp (CoinSelProp utxo txOuts) utxo' _)) = do
    isRight selection ==> let Right s = selection in prop s
  where
    prop coinSel = do
        let feeOpt = feeOptions 0 0
        coinSel' <- runExceptT (adjustForFees feeOpt utxo' coinSel)
        fmap ShowFmt coinSel' `shouldBe` Right (ShowFmt coinSel)
    selection = runIdentity $ runExceptT $
        largestFirst (CoinSelectionOptions 100) utxo txOuts

propDeterministic
    :: ShowFmt FeeProp
    -> Property
propDeterministic (ShowFmt (FeeProp (CoinSelProp utxo txOuts) _ (fee, dust))) = do
    isRight selection ==> let Right s = selection in prop s
  where
    prop coinSel = do
        let feeOpt = feeOptions fee dust
        let utxo' = mempty
        resultOne <- runExceptT $ adjustForFees feeOpt utxo' coinSel
        resultTwo <- runExceptT $ adjustForFees feeOpt utxo' coinSel
        resultOne `shouldBe` resultTwo
    selection = runIdentity $ runExceptT $
        largestFirst (CoinSelectionOptions 100) utxo txOuts

propReducedChanges
    :: SystemDRG
    -> ShowFmt FeeProp
    -> Property
propReducedChanges drg (ShowFmt (FeeProp (CoinSelProp utxo txOuts) utxo' (fee, dust))) = do
    isRight selection' ==>
        let (Right s, Right s') = (selection, selection') in prop s s'
  where
    prop coinSel coinSel' = do
        let chgs' = sum $ map getCoin $ change coinSel'
        let chgs = sum $ map getCoin $ change coinSel
        let inps' = inputs coinSel'
        let inps = inputs coinSel
        disjoin
            [ chgs' `shouldSatisfy` (<= chgs)
            , length inps' `shouldSatisfy` (>= length inps)
            ]
    selection = left show $ runIdentity $ runExceptT $
        largestFirst (CoinSelectionOptions 100) utxo txOuts
    selection' = selection >>= adjust
    feeOpt = feeOptions fee dust
    adjust s = left show $ fst $ withDRG drg $ runExceptT $
        adjustForFees feeOpt utxo' s

{-------------------------------------------------------------------------------
                         Fee Adjustment - Unit Tests
-------------------------------------------------------------------------------}

feeOptions
    :: Word64
    -> Word64
    -> FeeOptions
feeOptions fee dust = FeeOptions
    { estimate = \_num _outs ->
        Fee fee
    , dustThreshold =
        Coin dust
    }

feeUnitTest
    :: FeeFixture
    -> Either FeeError FeeOutput
    -> SpecWith ()
feeUnitTest (FeeFixture inpsF outsF chngsF utxoF feeF dustF) expected = it title $ do
    (utxo, sel) <- setup
    result <- runExceptT $ do
        (CoinSelection inps outs chngs) <-
            adjustForFees (feeOptions feeF dustF) utxo sel
        return $ FeeOutput
            { csInps = map (getCoin . coin . snd) inps
            , csOuts = map (getCoin . coin) outs
            , csChngs = map getCoin chngs
            }
    result `shouldBe` expected
  where
    setup :: IO (UTxO, CoinSelection)
    setup = do
        utxo <- generate (genUTxO utxoF)
        inps <- (Map.toList . getUTxO) <$> generate (genUTxO inpsF)
        outs <- generate (genTxOut outsF)
        let chngs = map Coin chngsF
        pure (utxo, CoinSelection inps outs chngs)

    title :: String
    title = mempty
        <> "CoinSelection (inps=" <> show inpsF
        <> "outs=" <> show outsF
        <> "chngs=" <> show chngsF
        <> "), UTxO=" <> show utxoF
        <> "), fee=" <> show feeF
        <> " --> " <> show expected

-- | A fixture for testing the fee calculation
data FeeFixture = FeeFixture
    { fInps :: [Word64]
        -- ^ Value (in Lovelace) & number of coins in inputs
    , fOuts :: [Word64]
        -- ^ Value (in Lovelace) & number of requested outputs
    , fChngs :: [Word64]
        -- ^ Value (in Lovelace) & number of changes
    , fUtxo :: [Word64]
        -- ^ Value (in Lovelace) & number of available coins in the UTxO
    , fFee :: Word64
        -- ^ Value (in Lovelace) of rigid fee
    , fDust :: Word64
        -- ^ Value (in Lovelace) of dust
    } deriving Show

-- | A fee calculation output
data FeeOutput = FeeOutput
    { csInps :: [Word64]
        -- ^ Value (in Lovelace) & number of available coins in the UTxO
    , csOuts :: [Word64]
        -- ^ Value (in Lovelace) & number of requested outputs
    , csChngs :: [Word64]
        -- ^ Value (in Lovelace) & number of changes
    } deriving (Show, Eq)

{-------------------------------------------------------------------------------
                            Arbitrary Instances
-------------------------------------------------------------------------------}

instance Arbitrary FeeProp where
    shrink (FeeProp cc utxo opts) =
        (\(cc', utxo') -> FeeProp cc' utxo' opts)
            <$> zip (shrink cc) (shrink utxo)
    arbitrary = do
        cc <- arbitrary
        utxo <- arbitrary
        fee <- choose (100000, 500000)
        dust <- choose (0, 10000)
        return $ FeeProp cc utxo (fee, dust)