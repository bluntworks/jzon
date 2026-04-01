# Changelog

## 2026-04-01

### Plan rewritten with Tiger-Style discipline

- Added Tiger-Style applicability matrix calibrating principles to jzon's domain (library, not safety-critical DB)
- Each component (`escape`, `scanner`, `path`, `writer`, `assembler`) now specifies bounded resources, state machine design, assertion vs error separation, comptime validation, and fuzz targets
- Added shared constants section with `comptime` cross-constraint validation (`MAX_DEPTH`, `MAX_PATH_SEGMENTS`, `MAX_ASSEMBLER_DEPTH`)
- Scanner and Assembler now have explicit state enums with validated transitions
- Writer uses typestate pattern and bounded nesting stack
- Added comprehensive testing strategy: roundtrip properties, fuzz targets for every input-facing component
- Rationale updated with Tiger-Style alignment section explaining zero-alloc, bounded resources, fatal/recoverable error separation, boundary validation, determinism, and explicit state machines
- Added bounds table documenting every resource limit with rationale
