// The tests' assertion: unlike precondition, its argument may `try` and `await`, and it holds in optimised builds.
func check(_ condition: Bool, file: StaticString = #file, line: UInt = #line) {
    if !condition { fatalError("check failed", file: file, line: line) }
}
