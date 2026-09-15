# tctiSH Utilities

These utilities are meant to augment using the tctiSH app -- often by running inside the tctiSH
environment. Accordingly, they should always produce something that's either statically linked or
interpretable using the base environment.

## Utilities

- `tctictl` - general configuration interface; used to configure tctiSH from inside it

## Host-Side Utilities

These run on the development machine rather than inside tctiSH.

- `jit-bless` is an LLDB script implementing the iOS 26+ JIT breakpoint protocol, so the JIT path
  can be debugged under Xcode without StikJIT in the loop
- `reflow-comments` refills Swift and Rust comment paragraphs -- doc comments to 80 columns, the
  rest to 100 -- which none of swift-format, SwiftFormat, rustfmt or clang-format will do: they all
  break a long line but never join short ones. `make format-swift` and `make format-rust` run it
  ahead of the real formatter, which rewrites code and never comments

To install it, put its import -- and nothing else -- in `~/.lldbinit-Xcode`:

```
command script import /path/to/tctiSH/utils/jit-bless/jit_bless.py
```

Xcode reads that file for every project on the machine, so the script scopes itself: it registers
its stop hook against the `qemu-x86_64-softmmu_jit` module alone, and LLDB rules stops out by module
before entering Python. Other projects see no handler, no output and no log file.
