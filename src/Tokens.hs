module Tokens where

import           Data.Int

import           Util

data Token = LPAREN
           | RPAREN
           | LBRACKET
           | RBRACKET
           | AT
           | SYMBOL String
           | INTEGER Int64
           | CHAR Char
           | STRING String
  deriving (Eq, Show)

data Form = RoundList [Form]
          | SquareList [Form]
          | At String Form
          | Symbol String
          | IntAtom Int64
          | CharAtom Char
          | StrAtom String
  deriving (Show)

instance Pretty Form where
  pretty (RoundList  forms) = "(" ++ unwords (map pretty forms) ++ ")"
  pretty (SquareList forms) = "[" ++ unwords (map pretty forms) ++ "]"
  pretty (At name form    ) = name ++ "@" ++ show form
  pretty (Symbol   s      ) = s
  pretty (IntAtom  i      ) = show i
  pretty (CharAtom c      ) = show c
  pretty (StrAtom  s      ) = show s
