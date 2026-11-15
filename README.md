# toml-zig

A TOML parser and writer for Zig. The library supports TOML 1.0 and 1.1, decodes a document directly into Zig types, and encodes them back. An edit patches spans of the source rather than rewriting the file, so comments, whitespace, ordering, and spelling survive byte for byte, on par with toml_edit and tomlkit.
