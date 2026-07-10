# Contributing to MeterBar

Thank you for your interest in contributing to MeterBar! This document provides guidelines and instructions for contributing.

## Code of Conduct

- Be respectful and inclusive
- Welcome newcomers and help them get started
- Focus on constructive feedback
- Respect different viewpoints and experiences

## How to Contribute

### Reporting Bugs

1. Check if the bug has already been reported in Issues
2. If not, create a new issue with:
   - Clear title and description
   - Steps to reproduce
   - Expected vs actual behavior
   - macOS version and app version
   - Screenshots if applicable

### Suggesting Features

1. Check if the feature has already been suggested
2. Create a new issue with:
   - Clear description of the feature
   - Use case and benefits
   - Potential implementation approach (optional)

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes following the coding standards
4. Test your changes thoroughly
5. Commit with clear messages (`git commit -m 'Add amazing feature'`)
6. Push to your branch (`git push origin feature/amazing-feature`)
7. Open a Pull Request

## Development Setup

### Prerequisites

- macOS 26 or later
- Xcode 26 or later
- Swift 6.2 toolchain (the project compiles in Swift 5 language mode)

### Building

1. Clone the repository:
   ```bash
   git clone <repo-url>
   cd meterbar.app
   ```

2. Open in Xcode:
   ```bash
   open MeterBar.xcodeproj
   ```

3. Build and run:
   - Select the `MeterBar` scheme
   - Press Cmd+R to build and run

## Coding Standards

### Swift Style

- Follow Swift API Design Guidelines
- Use meaningful variable and function names
- Add comments for complex logic
- Keep functions focused and small
- Use SwiftUI best practices

### Code Organization

- Group related files in folders
- Keep models, views, and services separate
- Use extensions for protocol conformance
- Follow the existing project structure

### Testing

- Write unit tests for business logic
- Test UI components manually
- Ensure all tests pass before submitting PR

## Commit Messages

Use clear, descriptive commit messages:

- `Add feature: [description]` for new features
- `Fix: [description]` for bug fixes
- `Update: [description]` for updates
- `Refactor: [description]` for refactoring
- `Docs: [description]` for documentation

## Questions?

Feel free to open an issue for questions or discussions!
