Terere Binary Format

Magic Number (4 bytes): TESB

[Instruction Section]
Instruction Count: u32
{{
Instructions: [InstructionCount]u32
}}

[Default Memory Pages]
DefaultPageCount: u8
{{
Page: u8
Offset: u16
Size: u16
Data Blob.....
}}

[Profile Extension Section]
ExtensionCount: u16
{{
    ExtensionID: u16
    Enable: bool (u8)
}}

[Debug Symbols Section]
SymbolCount: u32
{{
address: u32
len: u16
symbol: [len]u8
}}
