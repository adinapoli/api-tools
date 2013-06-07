{
{-# OPTIONS_GHC -w #-}

module Data.API.Scan
    ( scan
    , PToken
    , AlexPosn(..)
    , Token(..)
    ) where

import           Data.Char
import           Safe
}

%wrapper "posn"

$digit = 0-9            -- digits
$lower = [a-z_]         -- lower case & _
$upper = [A-Z]          -- upper case letters

tokens :-
    $white+                         ;
    "--".*                          ;
    "{-"(\n|[^\-]|\-[^\}])*"-}"     ;
    ";"                                 { simple    Semi            }
    "|"                                 { simple    Bar             }
    "["                                 { simple    Bra             }
    "]"                                 { simple    Ket             }
    "::"                                { simple    ColCol          }
    ":"                                 { simple    Colon           }
    "="                                 { simple    Equals          }
    "?"                                 { simple    Query           }
    ","                                 { simple    Comma           }
    version                             { simple    Version         }
    with                                { simple    With            }    
    integer                             { simple    Integer         }
    boolean                             { simple    Boolean         }
    utc                                 { simple    UTC             }
    string                              { simple    String          }
    binary                              { simple    Binary          }
    record                              { simple    Record          }
    union                               { simple    Union           }
    enum                                { simple    Enum            }
    basic                               { simple    Basic           }
    true                                { simple    TRUE            }
    false                               { simple    FALSE           }
      $upper [$lower $upper $digit]*    { mk        TypeIden        }
    \'$upper [$lower $upper $digit]*\'  { strip_qs  TypeIden        }
      $lower [$lower $upper $digit]*    { mk        VarIden         }
    \'$lower [$lower $upper $digit]*\'  { strip_qs  VarIden         }
    \"([^\\\"]|\\[\\\'\"])*\"           { string                    }
    $digit+                             { intg                      }
    "//".*                              { line_comment              }
    "(*"(\n|[^\*]|\*[^\)])*"*)"         { block_comment             }

{

type PToken = (AlexPosn,Token)

data Token
    = Semi
    | Bar
    | Binary
    | Bra
    | Ket
    | ColCol
    | Colon
    | Comma
    | Equals
    | Boolean
    | Integer
    | UTC
    | Query
    | Record
    | String
    | Union
    | Version
    | With
    | Enum
    | Basic
    | TRUE
    | FALSE
    | Comment  String
    | TypeIden String
    | VarIden  String
    | Intg     Int
    | Strg     String
    deriving (Eq,Show)

line_comment :: AlexPosn -> String -> PToken
line_comment = mk $ Comment . munch_ws . tailSafe . tailSafe 

block_comment :: AlexPosn -> String -> PToken
block_comment p (_:_:str) = 
    case reverse $ munch_ws str of
      _:_:rc -> (p,Comment $ reverse $ munch_ws rc)
      _      -> error "Scan.line_comment"
block_comment _ _ = error "Scan.line_comment" 

strip_qs :: (String->Token) -> AlexPosn -> String -> PToken
strip_qs f p (_:s) = (p,f $ initNote "Scan.strip_qs" s)
strip_qs _ _ _     = error "Scan.strip_qs"

munch_ws :: String -> String
munch_ws = dropWhile isSpace

simple :: Token -> AlexPosn -> String -> PToken
simple tk = mk $ const tk

intg :: AlexPosn -> String -> PToken
intg p s = (p,Intg $ readNote "Data.API.Scan.intg" s)

string :: AlexPosn -> String -> PToken
string = mk (Strg . f . chop)
  where
    f ""    = ""
    f (c:s) = case c of
                '\\' -> g s
                _    -> c : f s

    g ""    = ""
    g (c:s) = c : f s

chop :: String -> String
chop ""    = ""
chop (c:s) =
    case reverse s of
      ""   -> ""
      _:rs -> reverse rs

mk :: (String->Token) -> AlexPosn -> String -> PToken
mk f p s = (p,f s)

scan :: String -> [PToken]
scan = pp . alexScanTokens

pp :: [PToken] -> [PToken]
pp [] = []
pp (pt@(p@(AlexPn _ _ cn),_):inp) =
    case cn of
      1 -> (p,Semi):pt:pp inp
      _ ->          pt:pp inp

test :: IO ()
test = 
 do s <- getContents
    print (scan s)
}
