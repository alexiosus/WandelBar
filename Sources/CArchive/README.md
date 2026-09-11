# System libarchive bridge

The macOS SDK exposes `/usr/lib/libarchive` but does not ship its public C headers.
`archive.h` and `archive_entry.h` are upstream libarchive public interface headers,
vendored from the locally installed libarchive distribution. Their original BSD
license and copyright notices are preserved in each file. Only APIs available in
macOS 14's system library are used. No Homebrew or downloaded library is needed at
build time or runtime, and no private Apple API is used.
