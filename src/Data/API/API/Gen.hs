{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveDataTypeable         #-}

-- | This module contains datatypes generated from the DSL description
-- of the api-tools API; they thus correspond to the types in
-- "Data.API.Types".
module Data.API.API.Gen where

import           Data.API.API.DSL
import           Data.API.Tools

import           Language.Haskell.TH

$(generate         apiAPI)

$(generateAPITools apiAPI
                   [ enumTool
                   , jsonTool
                   , quickCheckTool
                   , lensTool
                   , safeCopyTool
                   , exampleTool
                   , samplesTool   (mkName "apiAPISamples")
                   , jsonTestsTool (mkName "apiAPISimpleTests")
                   ])
