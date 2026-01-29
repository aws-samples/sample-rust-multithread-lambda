# Contributing Guidelines

Thank you for your interest in contributing to this project!

## How to Contribute

We welcome contributions in the form of:
- Bug reports and feature requests via GitHub Issues
- Code contributions via Pull Requests
- Documentation improvements
- Performance benchmarks and test results

## Getting Started

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/your-feature-name`)
3. Make your changes
4. Test your changes thoroughly
5. Commit your changes with clear, descriptive messages
6. Push to your fork
7. Submit a Pull Request

## Code Standards

- Follow Rust best practices and idiomatic patterns
- Run `cargo fmt` before committing
- Run `cargo clippy` and address any warnings
- Ensure all tests pass with `cargo test`
- Add tests for new functionality
- Update documentation as needed

## Testing

Before submitting a PR:
- Build for both ARM64 and x86_64 architectures
- Run the validation test script: `./scripts/validation_test.sh`
- Verify your changes don't introduce performance regressions

## Pull Request Process

1. Update the README.md with details of changes if applicable
2. Ensure your code follows the existing style
3. Include relevant test results or benchmarks
4. Your PR will be reviewed by maintainers
5. Address any feedback or requested changes
6. Once approved, your PR will be merged

## Reporting Bugs

When reporting bugs, please include:
- A clear description of the issue
- Steps to reproduce
- Expected vs actual behavior
- Environment details (architecture, memory configuration, etc.)
- Any relevant logs or error messages

## Questions?

If you have questions about contributing, please open an issue with the "question" label.

## Code of Conduct

This project adheres to the [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.
