// Compile-only negative control; the function is intentionally undefined and never executed.
@_silgen_name("forbidden_dependency")
private func forbiddenDependency() -> Int

@c(arena_trace)
public func dependencyControl(_ capacity: Int) -> Int { forbiddenDependency() + capacity }
