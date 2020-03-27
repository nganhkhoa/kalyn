module Linker
  ( link
  )
where

import           Control.Exception
import           Data.ByteString.Builder
import qualified Data.ByteString.Lazy          as B

import           OS
import           Util

-- https://refspecs.linuxfoundation.org/elf/elf.pdf
-- https://uclibc.org/docs/elf-64-gen.pdf
--
-- Most of the necessary information is in the original ELF spec,
-- which is really quite good. However we are using ELF-64 and so it
-- is important to note that some of the fields have become 64-bit
-- instead of 32-bit in the headers.

data HeaderInfo = HeaderInfo
  { elfHeaderLen :: Int
  , phEntryLen :: Int
  , phNumEntries :: Int
  , shEntryLen :: Int
  , shNumEntries :: Int
  , headerPadding :: Int
  , codeLen :: Int
  , dataLen :: Int
  } deriving (Show)

phOffset :: HeaderInfo -> Int
phOffset = elfHeaderLen

shOffset :: HeaderInfo -> Int
shOffset info = phOffset info + (phEntryLen info * phNumEntries info)

codeOffset :: HeaderInfo -> Int
codeOffset info =
  shOffset info + (shEntryLen info * shNumEntries info) + headerPadding info

dataOffset :: HeaderInfo -> Int
dataOffset info = codeOffset info + codeLen info

-- see page 20
elfIdent :: B.ByteString
elfIdent =
  let hdr =
          toLazyByteString
            $  word8 0x7f -- magic bytes
            <> stringUtf8 "ELF"
            <> word8 2 -- address size, 64-bit
            <> word8 1 -- endianness, little-endian
            <> word8 1 -- version of ELF specification
  in  hdr <> B.pack (replicate (16 - fromIntegral (B.length hdr)) 0)

-- see page 18; for architecture codes see
-- <https://opensource.apple.com/source/dtrace/dtrace-90/sys/elf.h>
elfHeader :: HeaderInfo -> B.ByteString
elfHeader info =
  toLazyByteString
    $  lazyByteString elfIdent
    <> word16LE 3 -- file type, relocatable executable (called "shared object file")
    <> word16LE 62 -- architecture, x86_64
    <> word32LE 1 -- object file version
    <> word64LE (fromIntegral $ codeOffset info) -- entry point in virtual memory
    <> word64LE (fromIntegral $ phOffset info) -- program header offset
    <> word64LE (fromIntegral $ shOffset info) -- section header offset
    <> word32LE 0 -- processor-specific flags, none needed
    <> word16LE (fromIntegral $ elfHeaderLen info) -- ELF header size
    <> word16LE (fromIntegral $ phEntryLen info) -- program header entry length
    <> word16LE (fromIntegral $ phNumEntries info) -- program header entry count
    <> word16LE (fromIntegral $ shEntryLen info) -- section header entry size
    <> word16LE (fromIntegral $ shNumEntries info) -- section header entry count
    <> word16LE 0 -- index of string table in section header

-- see page 40
programHeader :: HeaderInfo -> [B.ByteString]
programHeader info =
  [ toLazyByteString -- code section
    $  word32LE 1 -- segment type, loadable code/data
    <> word32LE 0x5 -- permissions, read/execute only (see page 73)
    <> word64LE (fromIntegral $ codeOffset info) -- offset from beginning of file
    <> word64LE (fromIntegral $ codeOffset info) -- virtual address at which to map code/data
    <> word64LE 0 -- physical address at which to map, unused
    <> word64LE (fromIntegral $ codeLen info) -- number of bytes listed in file image
    <> word64LE (fromIntegral $ codeLen info) -- number of bytes to reserve in memory
    <> word64LE 0 -- alignment, none required
  , toLazyByteString -- data section
    $  word32LE 1 -- segment type, loadable code/data
    <> word32LE 0x6 -- permissions, read/write only (see page 73)
    <> word64LE (fromIntegral $ dataOffset info) -- offset from beginning of file
    <> word64LE (fromIntegral $ dataOffset info) -- virtual address at which to map code/data
    <> word64LE 0 -- physical address at which to map, unused
    <> word64LE (fromIntegral $ dataLen info) -- number of bytes listed in file image
    <> word64LE (fromIntegral $ dataLen info) -- number of bytes to reserve in memory
    <> word64LE 0 -- alignment, none required
  ]

-- see page 24
sectionHeader :: HeaderInfo -> [B.ByteString]
sectionHeader info =
  [ toLazyByteString -- index 0 (see page 27)
    $  word32LE 0
    <> word32LE 0
    <> word64LE 0
    <> word64LE 0
    <> word64LE 0
    <> word64LE 0
    <> word32LE 0
    <> word32LE 0
    <> word64LE 0
    <> word64LE 0
  , toLazyByteString
    $  word32LE 0 -- section name, none given
    <> word32LE 1 -- section type, program information
    <> word64LE 0x6 -- section attribute flags, executable memory
    <> word64LE (fromIntegral $ codeOffset info) -- memory address
    <> word64LE (fromIntegral $ codeOffset info) -- file address
    <> word64LE (fromIntegral $ codeLen info) -- segment length
    <> word32LE 0 -- section header table index link, unused
    <> word32LE 0 -- additional information, unused
    <> word64LE 0 -- alignment, none required
    <> word64LE 0 -- table entry size, unused
  , toLazyByteString
    $  word32LE 0 -- section name, none given
    <> word32LE 1 -- section type, program information
    <> word64LE 0x3 -- section attribute flags, writeable memory
    <> word64LE (fromIntegral $ dataOffset info) -- memory address
    <> word64LE (fromIntegral $ dataOffset info) -- file address
    <> word64LE (fromIntegral $ dataLen info) -- segment length
    <> word32LE 0 -- section header table index link, unused
    <> word32LE 0 -- additional information, unused
    <> word64LE 0 -- alignment, none required
    <> word64LE 0 -- table entry size, unused
  ]

-- see page 15
link :: (B.ByteString, B.ByteString) -> B.ByteString
link (codeB, dataB) =
  let (ehdr', phdr', shdr', hpad') =
          fixedPoint (B.empty, [B.empty], [B.empty], B.empty)
            $ \(ehdr, phdr, shdr, _) ->
                let phelen = B.length $ head phdr
                    shelen = B.length $ head shdr
                    headerLen =
                        fromIntegral (B.length ehdr)
                          + (fromIntegral phelen * length phdr)
                          + (fromIntegral shelen * length shdr)
                    info = HeaderInfo
                      { elfHeaderLen  = fromIntegral $ B.length ehdr
                      , phEntryLen    = fromIntegral phelen
                      , phNumEntries  = length phdr
                      , shEntryLen    = fromIntegral shelen
                      , shNumEntries  = length shdr
                      , headerPadding = leftover pageSize headerLen
                      , codeLen       = fromIntegral $ B.length codeB
                      , dataLen       = fromIntegral $ B.length dataB
                      }
                in  assert -- sanity check that all entries are same length
                      (  all (\phe -> B.length phe == phelen) phdr
                      && all (\she -> B.length she == shelen) shdr
                      )
                      ( elfHeader info
                      , programHeader info
                      , sectionHeader info
                      , B.pack $ replicate (headerPadding info) 0
                      )
  -- assume the assembler already put the appropriate padding between
  -- code and data so they don't share a page
  in  toLazyByteString
        $  lazyByteString ehdr'
        <> lazyByteString (mconcat phdr')
        <> lazyByteString (mconcat shdr')
        <> lazyByteString hpad'
        <> lazyByteString codeB
        <> lazyByteString dataB
