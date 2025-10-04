# Spring-CLI tool

A beautiful, interactive command-line tool for creating Spring Boot projects using Spring Initializr.

## Features

- 🎨 Interactive project creation with FZF
- ⚡ Quick project generation with sensible defaults
- 📦 Browse and select from all Spring dependencies
- 🔍 Version management for Spring Boot and Java
- 💾 Automatic backup before overwriting projects

## Installation

### Homebrew (macOS/Linux)
\`\`\`bash
brew install ch-shubham/tap/spring-cli-tool
\`\`\`

### Manual Installation
\`\`\`bash
curl -o /usr/local/bin/spring-cli https://raw.githubusercontent.com/ch-shubham/spring-cli-tool/main/spring-cli-tool.zsh
chmod +x /usr/local/bin/spring-cli-tool
\`\`\`

## Requirements

- jq: `brew install jq`
- fzf: `brew install fzf`
- zsh (usually pre-installed on macOS)

## Usage

\`\`\`bash
# Interactive mode (recommended)
spring-cli
sb

# Quick create
sb quick my-project web,data-jpa,lombok

# List dependencies
sb list-deps

# Show versions of spring boot
sb versions
\`\`\`

## License

MIT