# Contributing to Lintap

Thank you for your interest in contributing to Lintap. Questions, documentation
improvements, bug reports, feature proposals, and code contributions are welcome.
Please follow our [Code of Conduct](CODE_OF_CONDUCT.md) in all project interactions.

## Questions, Bugs, and Feature Requests

Search the [existing issues](https://github.com/LLNL/Lintap/issues) before opening
a new one. For bug reports, include:

- A clear description of the problem and the expected behavior
- Steps to reproduce the problem
- The relevant commit or version and Linux distribution/kernel version, where applicable
- Relevant logs or a minimal example, with private information removed

For feature proposals or substantial changes, open an issue first to discuss
the intended behavior and approach with the maintainers.

## Submitting a Contribution

1. Fork the repository and clone your fork.
2. Create a topic branch from the repository's default branch.
3. Make a focused change that follows the surrounding style.
4. Update documentation when your change affects usage or behavior. For code
   changes, add or update relevant tests and document how you verified the change.
5. Check your patch for whitespace errors with `git diff --check`.
6. Commit your changes with a descriptive message and push the branch to your fork.
7. Open a pull request against the default branch of
   [LLNL/Lintap](https://github.com/LLNL/Lintap). Describe the change, link related
   issues, and include verification results and any known limitations.
8. Respond to review feedback and update your branch as needed.

The current repository contains documentation and licensing files only; there
is no build system or automated test suite yet. Documentation contributions
should be checked for accurate statements, working links, and readable Markdown.
Implementation contributions should include the dependencies, build/run
instructions, and verification steps needed for reviewers to reproduce results.

## Review

The maintainers listed in [CODEOWNERS](CODEOWNERS) review contributions:
[@lindsey-w](https://github.com/lindsey-w),
[@david-frye](https://github.com/david-frye), and
[@grantjllnl](https://github.com/grantjllnl).

## Contribution License

Lintap is distributed under the [MIT License](LICENSE). All new contributions
must be made under that license. By submitting a contribution, you agree to
license it under the MIT License and confirm that you have the right to do so.
Preserve applicable copyright and license notices when incorporating third-party
material. See [NOTICE](NOTICE) for the LLNL auspice and disclaimer statements.
