# C- Language Reference

C- (pronounced "C Minus") is a stripped-down C dialect that compiles directly to TES assembly.
It has no libc, no heap allocator, and no preprocessor beyond `#include`.
It intentionally deviates from C in several places; this document explains both what exists
and every place it differs from C so you can tell whether unexpected behaviour is your code
or the compiler.

---

## 1. Types

| C- type    | Width    | Signed | C equivalent      |
|------------|----------|--------|-------------------|
| `u8`       | 1 byte   | No     | `unsigned char`   |
| `i8`       | 1 byte   | Yes    | `signed char`     |
| `u16`      | 2 bytes  | No     | `unsigned short`  |
| `i16`      | 2 bytes  | Yes    | `short`           |
| `u8_vec2`  | 2 bytes  | No     | *(no equivalent)* |
| `i8_vec2`  | 2 bytes  | Yes    | *(no equivalent)* |
| `void`     | 0 bytes  | —      | `void`            |

**Differences from C:**

- There is no `int`, `long`, `char`, `float`, `double`, `bool`, `size_t`, or `ptrdiff_t`.
- There are no implicit promotions. Arithmetic is done at the register width the compiler
  chooses; no "integer promotion to int" rules apply.
- `u8_vec2` and `i8_vec2` are 2-byte SIMD-style pair types that map to the TES vector
  instructions. They have no C analogue.
- There are no enums. Use `const` declarations instead (see §4).

---

## 2. Variable Declarations

```c
u16 count = 0;
u8  flag  = undefined;
const u8 MAX = 255;
```

**Differences from C:**

- Type comes **before** the name, same as C — but the type keywords are different (§1).
- `undefined` is an explicit keyword. Omitting an initializer is a compile error; if you
  want an uninitialized variable you must write `= undefined`. This prevents accidental UB.
  In C, uninitialized locals are just uninitialized.
- `const` works like C's `const` for locals and globals. There is no `volatile` or `restrict`.
- There are no typedefs. Named types come only from `struct`/`union` declarations.

### Register hints

```c
reg(RA) u16 ptr = 0;
```

The `reg(X)` prefix binds the variable to a specific hardware register. `X` is any TES
register name: `R0`–`R9`, `RA`–`RF`. This is guaranteed — the compiler will not spill it.
C has no equivalent (`register` in C is a hint that compilers ignore).

---

## 3. Arrays

```c
[8]u8   buffer;          // fixed-size array of 8 bytes
[*]u8   msg = "hello";   // flex array — size inferred from initialiser
```

**Differences from C:**

- Array size goes **before** the element type: `[8]u8` not `u8[8]`.
- `[*]type` is a flex array whose length is known at compile time from its initialiser
  (currently only string literals). Access `msg.len` to get the compile-time length as a
  constant. It is **not** stored at runtime anywhere; `msg.len` only works when the length
  is statically known.
- There is no pointer decay. An array name is an address, not a pointer value you can
  increment.
- There are no variable-length arrays (VLAs).

---

## 4. Constants

```c
const u8 MAX_VAL = 100;
```

Inside a function body you may also write a bare `const` without a type:

```c
const LIMIT = 64;       // type inferred from expression
```

**Differences from C:**

- C- `const` is a compile-time constant evaluated by the compiler. It is folded into
  instructions; no storage is allocated. C's `const` is merely a read-only variable with
  storage.
- There is no `#define`. Use `const` instead.

---

## 5. Structs and Unions

```c
struct Point {
    x: u16;
    y: u16;
};

union Sample {
    as_u16: u16;
    bytes:  [2]u8;
};
```

**Differences from C:**

- Field declarations use `name: type;` (colon separator), not `type name;`.
- You use the struct name directly without the `struct` keyword: `Point p;` not
  `struct Point p;`.
- Layout follows C ABI alignment rules (each field aligned to its natural alignment,
  struct padded to its largest member's alignment).
- No anonymous structs or unions inside structs.
- No bit-fields.
- No flexible array members (C99 `type arr[];`).

---

## 6. Functions

```c
fn add(a: u16, b: u16) u16 {
    return a + b;
}

inline fn clamp(v: u8, lo: u8, hi: u8) u8 {
    return v < lo ? lo : (v > hi ? hi : v);
}
```

**Differences from C:**

- Syntax is `fn name(param: type, ...) return_type` — **type after name**, not before.
- `inline fn` is **always** inlined. The compiler never makes an inline call a regular call.
  C's `inline` keyword is a hint; compilers may ignore it.
- There are no variadic functions (`...`).
- There are no default argument values.
- Forward declarations are not needed — the compiler does a forward-reference pass.
- There is no `static` keyword for functions.

### Calling convention

| Role             | Registers     | Notes                                          |
|------------------|---------------|------------------------------------------------|
| Parameters 1–10  | `r0`–`r9`    | First param in `r0`, second in `r1`, etc.      |
| Extra parameters | Stack         | Pushed right-to-left if more than 10 params    |
| Return value     | `r0`         | Additional return values spill into `r1`–`r9`  |
| Scratch          | `ra`–`rf`    | Caller-saved; callee preserves them if needed  |

The compiler uses `bn callee` (branch-and-link, saves IP+1 to `jr`) and `b jr` for
return. Prologue saves `jr`; epilogue restores and jumps.

---

## 7. Pointers

C- has two kinds of pointers because TES memory is paged (256 pages × 64 KiB).

### Page-0 pointer (single u16)

```c
u16 addr = 0x0400;
*addr = 42;             // write 42 to page-0 address 0x0400
u8 v = *addr;           // read from page-0
```

A bare `u16` used with `*` addresses page 0. This is the common case for data globals,
which all live on page 0.

### Extended pointer (page, offset pair)

```c
u16 page = 255;
u16 off  = 0x0000;

*(page, off) = 99;      // write to page 255, offset 0
u8 v = *(page, off);    // read from page 255, offset 0
```

### Taking an address

```c
// Page-0 global → single u16
u16 addr = &myGlobal;

// Any symbol → (page, offset) pair
(u8 pg, u16 of) = &myFunction;
(pg, of)(arg0, arg1);           // indirect call through (page, offset)
```

**Differences from C:**

- There is no `*type` pointer type. Pointers are raw `u16` (page-0) or `(u16, u16)` pairs.
- You cannot do pointer arithmetic with `+` or `-` on pointer variables directly.
- Function calls through a pointer use `(page, offset)(args)` syntax, not `(*ptr)(args)`.
- `&symbol` on a page-0 symbol returns a `u16`; on any other symbol it fills a `(page, offset)` pair.
- There is no `NULL`. Use `0` if you need a sentinel.

---

## 8. Control Flow

All control-flow constructs are identical to C in semantics. Syntax differences only:

### if / else

```c
if (condition) {
    // ...
} else if (other) {
    // ...
} else {
    // ...
}
```

No differences from C syntax here.

### while

```c
while (condition) {
    // ...
}
```

### do-while

```c
do {
    // ...
} while (condition);
```

### for

```c
for (u16 i = 0; i < 10; i++) {
    // ...
}
```

**Difference from C:** The init clause requires a full variable declaration including type
(`u16 i = 0`), not just an expression. You cannot do `for (i = 0; ...)` without declaring `i`.

### break and continue

Work exactly as in C inside `while`, `do-while`, and `for` loops.

---

## 9. Inline For (Unrolled Loop)

```c
inline for (u8 i : 0..8) {
    buffer[i] = 0;      // i is a compile-time constant in each iteration
}
```

**This has no C equivalent.**

- The compiler fully unrolls the loop at compile time.
- `i` is treated as a compile-time integer constant inside the body, not a runtime variable.
- Range is `start..end` (exclusive end), both values must be compile-time constants.
- Use this when you need guaranteed unrolling (e.g., for SIMD initialisation or when
  loop-carried state would prevent normal vectorisation).

---

## 10. Inline Assembly

```c
asm {
    mov ra, 255
    syscall cat_GFX, GFXSync
};
```

**Differences from C:**

- The block is `asm { ... }` not `asm("...")` or `__asm__ volatile(...)`.
- Lines inside the block are literal TES assembly and are pasted verbatim into the output.
- There are no input/output constraints (no `"=r"(var)` bindings). If you need to read or
  write C- variables from inline asm, put them in known registers with `reg(X)` variables
  beforehand.

---

## 11. String Literals

```c
[*]u8 greeting = "Hello\n";
```

- String literals are ASCII byte arrays with a null terminator appended automatically.
- Escape sequences supported: `\n`, `\r`, `\t`, `\0`, `\\`, `\"`, `\'`.
- All string literals are stored in the data section on page 0.
- `greeting.len` gives the length **including** the null terminator as a compile-time constant.

**Differences from C:**

- The type of a string literal is `[*]u8`, not `const char *`.
- You cannot do pointer arithmetic on string literals.
- String literals are **not** implicitly convertible to `u16` (pointer) — use `&greeting` to
  get the page-0 address.

---

## 12. Memory Layout

| Region                | Page | Offset range          | Notes                         |
|-----------------------|------|-----------------------|-------------------------------|
| Interrupt vector table| 0    | `0x0000`–`0x03FF`    | Reserved; do not use          |
| Global data / strings | 0    | `0x0400` and up       | Compiler assigns automatically|
| Code (instructions)   | 1    | `0x0000` and up       | TBF instruction array         |

- All globals and string literals are assigned consecutive addresses on page 0 starting
  at `0x0400`, in declaration order, aligned to their natural alignment.
- The compiler does not emit heap management. There is no `malloc`/`free`.
- Stack is managed by `stackset` in your bootstrap; the compiler uses `push`/`pop` normally.

---

## 13. What Is Not Implemented

The following exist in the spec or AST but have **not yet been implemented** in codegen,
or have significant limitations:

| Feature                       | Status / Limitation                                            |
|-------------------------------|----------------------------------------------------------------|
| `u8_vec2` / `i8_vec2` ops     | Types parsed and stored; vector arithmetic not fully codegen'd |
| Multi-register return         | Only `r0` is used for return values currently                  |
| Named struct type as variable | Struct fields work; struct-typed locals may not codegen fully  |
| `[*]u8` flex array            | Works for string literal globals; other uses unverified        |
| `#include`                    | Token is lexed but not processed — include is a no-op          |
| `import`                      | Keyword reserved, not implemented                              |
| Non-page-0 data pointers      | `(page, off)` syntax parsed; codegen may be incomplete         |

---

## 14. Quick Syntax Comparison

| Concept              | C                          | C-                              |
|----------------------|----------------------------|---------------------------------|
| Function declaration | `int add(int a, int b)`    | `fn add(a: i16, b: i16) i16`   |
| Variable declaration | `unsigned short x = 0;`    | `u16 x = 0;`                   |
| Struct field         | `unsigned char r;`         | `r: u8;`                       |
| Array type           | `char buf[16]`             | `[16]u8 buf`                   |
| Uninitialized var    | `int x;`                   | `u16 x = undefined;`           |
| Compile constant     | `#define MAX 100`          | `const MAX = 100;`             |
| Register binding     | *(none)*                   | `reg(R0) u8 x = 0;`            |
| Unrolled loop        | `#pragma unroll` / manual  | `inline for (u8 i : 0..N)`     |
| Page-0 deref         | `*ptr`                     | `*addr`                        |
| Extended deref       | *(none)*                   | `*(page, addr)`                |
| Inline asm           | `asm("..." : ...)`         | `asm { raw_tes_line }`         |
| Struct use           | `struct Point p;`          | `Point p;`                     |
| Boolean false        | `false` or `0`             | `0` (no bool type)             |
| Null pointer         | `NULL`                     | `0`                            |
| String type          | `const char *`             | `[*]u8`                        |
