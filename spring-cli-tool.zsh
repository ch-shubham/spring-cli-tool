#!/usr/bin/env zsh

# Spring Initializr CLI Tool with FZF
# A complete command-line interface for creating Spring Boot projects

alias run-sb='./mvnw spring-boot:run'

backupsb() {
    if [ -z "$1" ]; then
        echo "Usage: backup <file_or_directory>"
        return 1
    fi
    
    if [ ! -e "$1" ]; then
        echo "Error: $1 does not exist"
        return 1
    fi

    # local backup_dir="$HOME/Workspace/backups"
    local backup_dir="${SPRING_CLI_BACKUP_DIR:-$HOME/.spring-cli/backups}"
    mkdir -p "$backup_dir"

    local timestamp=$(date +%d-%b-%Y_%Hh%Mm%Ss)
    local backup_file_name="$1.bak.sb.$timestamp"
    local backup_file="$backup_dir/${backup_file_name}"

    if [ -d "$1" ]; then
        cp -r "$1" "$backup_file" && echo "✓ Backed up to: $backup_file"
    else
        cp "$1" "$backup_file" && echo "✓ Backed up to: $backup_file"
    fi
}


spring-cli() {
    local SPRING_API="https://start.spring.io"
    # Defaults
    local DEFAULT_JAVA=21
    # Allow user to override default Java via environment var SPRING_CLI_DEFAULT_JAVA
    local JAVA_PREF=${SPRING_CLI_DEFAULT_JAVA:-$DEFAULT_JAVA}
    
    # Colors - using printf for better compatibility
    local GREEN=$'\033[0;32m'
    local BLUE=$'\033[0;34m'
    local YELLOW=$'\033[1;33m'
    local RED=$'\033[0;31m'
    local NC=$'\033[0m'
    local BOLD=$'\033[1m'
    local CYAN=$'\033[0;36m'

    # # Cleanup on interruption
    # trap 'cleanup_on_exit' INT TERM

    # cleanup_on_exit() {
    #     printf "\n${YELLOW}🛑 Operation cancelled${NC}\n"
    #     # Clean up any partial downloads
    #     rm -f *.zip.tmp spring-*.zip 2>/dev/null
    #     exit 130
    # }

    # Check for required tools
    check_requirements() {
        local missing=()
        
        if ! command -v jq &> /dev/null; then
            missing+=("jq")
        fi
        
        if ! command -v fzf &> /dev/null; then
            missing+=("fzf")
        fi
        
        if [[ ${#missing[@]} -gt 0 ]]; then
            printf "${RED}❌ Missing required tools: ${missing[*]}${NC}\n"
            printf "${YELLOW}Install with: brew install ${missing[*]}${NC}\n"
            return 1
        fi
        return 0
    }

    # Fetch live metadata
    fetch_metadata() {
        printf "${BLUE}📡 Fetching latest Spring Initializr options...${NC}\n" >&2
        local metadata=$(curl -s "$SPRING_API/metadata/client")
        if [[ $? -eq 0 && -n "$metadata" ]]; then
            echo "$metadata"
            return 0
        else
            printf "${RED}❌ Failed to fetch metadata${NC}\n" >&2
            return 1
        fi
    }

    # Test if a boot version works with the API
    test_boot_version_api() {
        local boot_version=$1
        local test_url="${SPRING_API}/starter.zip?type=maven-project&language=java&bootVersion=${boot_version}&javaVersion=21&baseDir=test-$$&groupId=com.test&artifactId=test&name=test&packageName=com.test&packaging=jar"
        local response=$(curl -s -o /dev/null -w "%{http_code}" "$test_url")
        echo "Response code for version '$boot_version': $response"
        [[ "$response" -eq 200 ]]
    }

    # Resolve and normalize a Spring Boot version candidate against metadata
    resolve_boot_version() {
        local metadata=$1
        local candidate=$2

        # If metadata is missing or invalid, sanitize and return candidate (or fallback default)
        if [[ -z "$metadata" ]] || ! echo "$metadata" | jq empty 2>/dev/null; then
            if [[ -n "$candidate" ]]; then
                echo "$candidate" | sed -E 's/\.RELEASE$//I; s/-RELEASE$//I; s/^v//i'
            else
                # Fallback to a reasonable default Spring Boot version
                echo "3.5.6"
            fi
            return 0
        fi

        # Get available boot version ids
        local avail=$(echo "$metadata" | jq -r '.bootVersion.values[].id' 2>/dev/null || true)

        # Helper: pick default or highest stable
        pick_default() {
            printf "${YELLOW}⚠️  Version '$candidate' not found, using $default_version${NC}\n" >&2
            local def=$(echo "$metadata" | jq -r '.bootVersion.default // empty' 2>/dev/null)
            if [[ -n "$def" ]]; then
                echo "$def"
                return 0
            fi
            # highest non-SNAPSHOT
            echo "$avail" | grep -v -i snapshot | sort -V | tail -n1
        }

        # If candidate empty, return default/highest (normalized)
        if [[ -z "$candidate" ]]; then
            local default_version=$(pick_default)
            # Normalize the default version before returning
            echo "$default_version" | sed -E 's/\.RELEASE$//I; s/-RELEASE$//I; s/^v//i'
            return 0
        fi

        # ALWAYS sanitize first
        local sanitized=$(echo "$candidate" | sed -E 's/\.RELEASE$//I; s/-RELEASE$//I; s/^v//i')
        
        # Check if sanitized version exists in available versions
        if [[ -n "$sanitized" ]] && echo "$avail" | grep -x -- "$sanitized" >/dev/null 2>&1; then
            echo "$sanitized"
            return 0
        fi

        # If the original candidate exists (even with .RELEASE), return sanitized version
        if echo "$avail" | grep -x -- "$candidate" >/dev/null 2>&1; then
            echo "$sanitized"
            return 0
        fi

        # Try matching by prefix (e.g., candidate '3.5.6.RELEASE' -> match '3.5.6')
        local prefix=$(echo "$sanitized" | awk -F'[.-]' '{print $1"."$2"."$3}' 2>/dev/null || true)
        if [[ -n "$prefix" ]] && echo "$avail" | grep -E "^${prefix}" >/dev/null 2>&1; then
            # pick the highest matching prefix and sanitize it
            local matched=$(echo "$avail" | grep -E "^${prefix}" | sort -V | tail -n1)
            echo "$matched" | sed -E 's/\.RELEASE$//I; s/-RELEASE$//I; s/^v//i'
            return 0
        fi

        # Optionally verify with API if SPRING_CLI_VERIFY_VERSION is set
        if [[ -n "${SPRING_CLI_VERIFY_VERSION}" ]]; then
            if ! test_boot_version_api "$sanitized" 2>/dev/null; then
                # If normalized version fails, try the original
                if [[ "$sanitized" != "$candidate" ]] && test_boot_version_api "$candidate" 2>/dev/null; then
                    printf "${YELLOW}⚠️  API requires version format: $candidate${NC}\n" >&2
                    echo "$candidate"
                    return 0
                fi
            fi
        fi

        # As a last resort, return default/highest (normalized)
        local default_version=$(pick_default)
        echo "$default_version" | sed -E 's/\.RELEASE$//I; s/-RELEASE$//I; s/^v//i'
        return 0
    }
    
    # FZF select with preview
    fzf_select() {
        local title=$1
        local metadata=$2
        local field=$3
        local preview_field=${4:-name}
        
        local options=$(echo "$metadata" | jq -r ".$field.values[] | \"\(.id)│\(.name)│\(.description // \"\")\""  2>/dev/null)
        
        if [[ -z "$options" ]]; then
            printf "${RED}❌ No options available for $field${NC}\n" >&2
            return 1
        fi
        
        local selected=$(echo "$options" | fzf \
            --height=50% \
            --border=rounded \
            --prompt="$title > " \
            --header="↑↓ Navigate • Enter Select • Esc Cancel" \
            --preview="echo {} | cut -d'│' -f2,3 | sed 's/│/\\n\\n/'" \
            --preview-window=up:3:wrap \
            --delimiter='│' \
            --with-nth=1,2 \
            --ansi)

        if [[ -n "$selected" ]]; then
            echo "$selected" | cut -d'│' -f1
            return 0
        else
            return 1
        fi
    }

    # Validate dependencies (prevent injection)
    validate_dependencies() {
        local deps=$1
        # Ensure dependencies contain only valid characters (alphanumeric, dash, comma, underscore)
        if [[ ! "$deps" =~ ^[a-zA-Z0-9,._-]*$ ]]; then
            printf "${RED}❌ Invalid dependency format${NC}\n" >&2
            return 1
        fi
        echo "$deps"
        return 0
    }

    # FZF multi-select for dependencies
    fzf_select_dependencies() {
        local metadata=$1
        
        printf "${BLUE}📦 Loading dependencies...${NC}\n" >&2
        
        # First, let's check if metadata is valid
        if ! echo "$metadata" | jq empty 2>/dev/null; then
            printf "${RED}❌ Invalid metadata JSON${NC}\n" >&2
            return 1
        fi
        
        # The actual Spring Initializr structure has dependencies.values as an array of groups
        # Each group has: name (category), values (array of dependencies)
        local deps=""
        deps=$(echo "$metadata" | jq -r '
            .dependencies.values[]? | 
            .name as $category | 
            .values[]? | 
            "\(.id)│\(.name)│\($category)│\(.description // "No description")"
        ' 2>/dev/null || true)
        
        if [[ -z "$deps" ]]; then
            printf "${YELLOW}⚠️ No dependencies found in metadata${NC}\n" >&2
            # Save debug info
            echo "$metadata" > /tmp/spring-metadata-debug.json
            printf "${YELLOW}Debug: Raw metadata saved to /tmp/spring-metadata-debug.json${NC}\n" >&2
            echo ""
            return 0
        fi
        
        # Count dependencies
        local dep_count=$(echo "$deps" | wc -l | tr -d ' ')
        printf "${GREEN}✓ Found ${dep_count} dependencies${NC}\n" >&2
        
        local selected=$(echo "$deps" | fzf \
            --multi \
            --height=80% \
            --border=rounded \
            --prompt="Dependencies (Tab to select multiple) > " \
            --header="Tab: Select • Enter: Confirm • Ctrl-A: Select All • Ctrl-D: Deselect All • Esc: Skip" \
            --preview="echo {} | cut -d'│' -f2,4 | sed 's/│/\\n\\n/'" \
            --preview-window=up:5:wrap \
            --delimiter='│' \
            --with-nth=1,2,3 \
            --bind 'ctrl-a:select-all' \
            --bind 'ctrl-d:deselect-all' \
            --ansi)
        
        if [[ -n "$selected" ]]; then
            local deps_list=$(echo "$selected" | cut -d'│' -f1 | tr '\n' ',' | sed 's/,$//')
            validate_dependencies "$deps_list"
            return $?
        else
            echo ""
            return 0
        fi
    }

    # Interactive text input with default
    get_input() {
        local prompt=$1
        local default=$2
        local value
        
        printf "${BLUE}$prompt${NC} ${YELLOW}[$default]${NC}: " >&2
        read value
        echo "${value:-$default}"
    }

    # Show project summary
    show_summary() {
        local name=$1
        local group=$2
        local artifact=$3
        local package=$4
        local type=$5
        local language=$6
        local boot_version=$7
        local java_version=$8
        local packaging=$9
        local dependencies=${10}
        
        local deps_display="${dependencies//,/, }"
        [[ -z "$deps_display" ]] && deps_display="(none)"
        
        printf "${CYAN}╔══════════════════════════════════════════════╗${NC}\n"
        printf "${CYAN}║           📋 PROJECT SUMMARY                 ║${NC}\n"
        printf "${CYAN}╚══════════════════════════════════════════════╝${NC}\n\n"
        printf "${BOLD}📝 Project Information:${NC}\n"
        printf "   ${GREEN}Name:${NC}           $name\n"
        printf "   ${GREEN}Group:${NC}          $group\n"
        printf "   ${GREEN}Artifact:${NC}       $artifact\n"
        printf "   ${GREEN}Package:${NC}        $package\n\n"
        printf "${BOLD}🔧 Configuration:${NC}\n"
        printf "   ${GREEN}Type:${NC}           $type\n"
        printf "   ${GREEN}Language:${NC}       $language\n"
        printf "   ${GREEN}Boot Version:${NC}   $boot_version\n"
        printf "   ${GREEN}Java Version:${NC}   $java_version\n"
        printf "   ${GREEN}Packaging:${NC}      $packaging\n\n"
        printf "${BOLD}📦 Dependencies:${NC}\n"
        printf "   ${YELLOW}$deps_display${NC}\n"
    }

    # Interactive mode with FZF
    interactive_mode() {
        if ! check_requirements; then
            return 1
        fi
        
        printf "${BOLD}${BLUE}"
        printf "╔══════════════════════════════════════════════╗\n"
        printf "║     🚀 Spring Initializr CLI Tool v0.0.1      ║\n"
        printf "║      Create Spring Boot projects with FZF   ║\n"
        printf "╚══════════════════════════════════════════════╝\n"
        printf "${NC}\n\n"
        printf "${YELLOW}⚠️  DEVELOPMENT VERSION - Errors may occur${NC}\n"
        printf "${YELLOW}💡 Tip: If pom.xml version errors occur, manually remove${NC}\n"
        printf "${YELLOW}   -BUILD, or -RELEASE suffixes and rebuild${NC}\n\n"
        
        # Fetch metadata once
        local metadata=$(fetch_metadata)
        if [[ $? -ne 0 ]]; then
            printf "${RED}❌ Failed to fetch metadata. Check internet connection.${NC}\n"
            return 1
        fi
        
        printf "${GREEN}✓ Metadata loaded successfully${NC}\n\n"
        
        # Declare associative array for config
        typeset -A config
        
        # Project Name
        config[name]=$(get_input "Project name" "demo")
        
        # Check if directory exists
        if [[ -d "${config[name]}" ]]; then
            printf "${YELLOW}⚠️  Directory '${config[name]}' already exists${NC}\n"
            read "overwrite?Overwrite? (y/N): "
            if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                printf "${YELLOW}Cancelled${NC}\n"
                return 0
            fi
            backupsb "${config[name]}"
            echo "${YELLOW}💡 Tip: existing directory backed up${NC}. Please delete manually if not needed."
            rm -rf "${config[name]}"
        fi
        
        # Project Type (Maven/Gradle) with FZF
        printf "\n${BLUE}📦 Selecting Project Type...${NC}\n"
        config[type]=$(fzf_select "Project Type" "$metadata" "type")
        if [[ $? -ne 0 ]]; then
            printf "${YELLOW}Cancelled${NC}\n"
            return 0
        fi
        
        # Language with FZF
        printf "\n${BLUE}☕ Selecting Language...${NC}\n"
        config[language]=$(fzf_select "Language" "$metadata" "language")
        if [[ $? -ne 0 ]]; then
            printf "${YELLOW}Cancelled${NC}\n"
            return 0
        fi
        
        # Spring Boot Version with FZF
        printf "\n${BLUE}🚀 Selecting Spring Boot Version...${NC}\n"
        config[boot_version]=$(fzf_select "Spring Boot Version" "$metadata" "bootVersion")
        if [[ $? -ne 0 ]]; then
            printf "${YELLOW}Cancelled${NC}\n"
            return 0
        fi
        # Normalize/resolve boot version against metadata (strip .RELEASE etc.)
        config[boot_version]=$(resolve_boot_version "$metadata" "${config[boot_version]}")
        
        # Java Version with FZF
        printf "\n${BLUE}☕ Selecting Java Version...${NC}\n"
        config[java_version]=$(fzf_select "Java Version" "$metadata" "javaVersion")
        if [[ $? -ne 0 ]]; then
            printf "${YELLOW}Cancelled${NC}\n"
            return 0
        fi
        
        # Packaging with FZF
        printf "\n${BLUE}📦 Selecting Packaging...${NC}\n"
        config[packaging]=$(fzf_select "Packaging" "$metadata" "packaging")
        if [[ $? -ne 0 ]]; then
            printf "${YELLOW}Cancelled${NC}\n"
            return 0
        fi
        
        # Group ID
        config[group]=$(get_input "Group ID" "com.example")
        
        # Artifact ID
        config[artifact]=$(get_input "Artifact ID" "${config[name]}")
        
        # Package Name
        config[package]=$(get_input "Package name" "${config[group]}.${config[artifact]}")
        
        # Dependencies with FZF multi-select
        printf "\n${BLUE}📦 Selecting Dependencies...${NC}\n"
        printf "${YELLOW}Tip: Use Tab to select multiple, Enter to confirm${NC}\n"
        config[dependencies]=$(fzf_select_dependencies "$metadata")
        if [[ $? -ne 0 ]]; then
            printf "${RED}❌ Invalid dependencies${NC}\n"
            return 1
        fi
        
        # Show summary
        echo ""
        show_summary "${config[name]}" "${config[group]}" "${config[artifact]}" \
                     "${config[package]}" "${config[type]}" "${config[language]}" \
                     "${config[boot_version]}" "${config[java_version]}" \
                     "${config[packaging]}" "${config[dependencies]}"
        echo ""
        
        # Confirm
        read "confirm?${GREEN}Create project? (Y/n):${NC} "
        if [[ "$confirm" =~ ^[Nn]$ ]]; then
            printf "${YELLOW}❌ Cancelled${NC}\n"
            return 0
        fi
        
        # Create project
        printf "\n${BLUE}🚀 Creating project '${config[name]}'...${NC}\n"
        
        local url="$SPRING_API/starter.zip"
        url+="?type=${config[type]}"
        url+="&language=${config[language]}"
        url+="&bootVersion=${config[boot_version]}"
        url+="&baseDir=${config[name]}"
        url+="&groupId=${config[group]}"
        url+="&artifactId=${config[artifact]}"
        url+="&name=${config[name]}"
        url+="&packageName=${config[package]}"
        url+="&packaging=${config[packaging]}"
        url+="&javaVersion=${config[java_version]}"
        
        echo "Request URL: $url"

        if [[ -n "${config[dependencies]}" ]]; then
            url+="&dependencies=${config[dependencies]}"
        fi
        
        # Download and extract
        local http_code=$(curl -s -w "%{http_code}" -o "${config[name]}.zip" "$url")
        
        if [[ "$http_code" -eq 200 ]]; then
            if unzip -q "${config[name]}.zip" 2>/dev/null; then
                rm "${config[name]}.zip"
                
                if [[ ! -d "${config[name]}" ]]; then
                    printf "${RED}❌ Project directory not created${NC}\n"
                    return 1
                fi
                
                cd "${config[name]}" || {
                    printf "${RED}❌ Cannot enter project directory${NC}\n"
                    return 1
                }
                
                printf "\n${GREEN}✅ Project created successfully!${NC}\n"
                printf "${BOLD}📁 Location:${NC} $(pwd)\n"
                
                if [[ "${config[type]}" == "maven-project" ]]; then
                    printf "${BOLD}▶️  Run with: run-sb${NC} OR ./mvnw spring-boot:run\n"
                else
                    printf "${BOLD}▶️  Run with:${NC} ./gradlew bootRun\n"
                fi
                
                # Offer to open in IDE
                echo ""
                read "open_ide?${BLUE}Open in IntelliJ IDEA? (y/N):${NC} "
                if [[ "$open_ide" =~ ^[Yy]$ ]]; then
                    if command -v idea &> /dev/null; then
                        idea .
                        printf "${GREEN}✓ Opening in IntelliJ IDEA...${NC}\n"
                    else
                        open -a "IntelliJ IDEA" . 2>/dev/null || printf "${YELLOW}IntelliJ IDEA not found${NC}\n"
                    fi
                fi
            else
                printf "${RED}❌ Failed to extract project archive${NC}\n"
                rm -f "${config[name]}.zip"
                return 1
            fi
        elif [[ "$http_code" -eq 500 ]]; then
            printf "${RED}❌ Server error (HTTP 500)${NC}\n"
            printf "${YELLOW}💡 This usually means the Spring Boot version is incompatible${NC}\n"
            printf "${YELLOW}   Suggested fixes:${NC}\n"
            printf "${YELLOW}   • Try a stable release version (e.g., 3.3.5, 3.4.0)${NC}\n"
            printf "${YELLOW}   • Avoid SNAPSHOT or BUILD versions${NC}\n"
            printf "${YELLOW}   • Run 'spring-cli versions' to see available versions${NC}\n"
            rm -f "${config[name]}.zip"
            return 1
        else
            printf "${RED}❌ Failed to create project (HTTP $http_code)${NC}\n"
            rm -f "${config[name]}.zip"
            return 1
        fi
    }

    # Quick create with minimal prompts
    quick_create() {
        local name=${1:-demo}
        local deps=${2:-web}
        
        printf "${YELLOW}⚠️  DEVELOPMENT VERSION - Errors may occur${NC}\n"
        printf "${YELLOW}💡 Tip: If build fails, check pom.xml and remove -SNAPSHOT,${NC}\n"
        printf "${YELLOW}   -BUILD, or -RELEASE version suffixes${NC}\n\n"
        

        if ! check_requirements; then
            return 1
        fi
        
        # Validate dependencies
        if ! validate_dependencies "$deps" >/dev/null 2>&1; then
            printf "${RED}❌ Invalid dependency format${NC}\n"
            return 1
        fi
        
        # Check if directory exists
        if [[ -d "$name" ]]; then
            printf "${YELLOW}⚠️  Directory '$name' already exists${NC}\n"
            read "overwrite?Overwrite? (y/N): "
            if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
                printf "${YELLOW}Cancelled${NC}\n"
                return 0
            fi

            backupsb "$name"
            echo "${YELLOW}💡 Tip: existing directory backed up${NC}. Please delete manually if not needed."
            rm -rf "$name"
        fi
        
        printf "${BLUE}🚀 Quick creating Spring Boot project: $name${NC}\n"
        
        # Fetch metadata for latest stable Spring Boot and Java default
        local metadata=$(curl -s "$SPRING_API/metadata/client")
        local latest_boot=""
        local latest_java="$DEFAULT_JAVA"

        if [[ -n "$metadata" ]] && echo "$metadata" | jq empty 2>/dev/null; then
            # Prefer the 'default' if provided, otherwise pick the highest stable version
            latest_boot=$(echo "$metadata" | jq -r '.bootVersion.default // empty')
            if [[ -z "$latest_boot" ]]; then
                # Choose the highest non-SNAPSHOT semantic version if possible
                latest_boot=$(echo "$metadata" | jq -r '.bootVersion.values[].id' 2>/dev/null | grep -v -i snapshot | sort -V | tail -n1)
            fi

            latest_java=$(echo "$metadata" | jq -r '.javaVersion.default // empty')
            if [[ -z "$latest_java" ]]; then
                latest_java=$DEFAULT_JAVA
            fi
        fi

        # Ensure we have a normalized available boot version
        latest_boot=$(resolve_boot_version "$metadata" "$latest_boot")

        printf "${BLUE}Using Spring Boot ${latest_boot:-(unknown)}, Java ${latest_java}${NC}\n"

        local http_code=$(curl -s -w "%{http_code}" -o "$name.zip" "$SPRING_API/starter.zip" \
            -d type=maven-project \
            -d language=java \
            -d bootVersion=${latest_boot} \
            -d baseDir=$name \
            -d groupId=com.example \
            -d artifactId=$name \
            -d name=$name \
            -d packageName=com.example.$name \
            -d packaging=jar \
            -d javaVersion=${latest_java} \
            -d dependencies=$deps)
        
        if [[ "$http_code" -eq 200 ]]; then
            if unzip -q $name.zip 2>/dev/null; then
                rm $name.zip
                cd "$name" || {
                    printf "${RED}❌ Cannot enter project directory${NC}\n"
                    return 1
                }
                printf "${GREEN}✅ Project '$name' created!${NC}\n"
                printf "${BOLD}▶️  Run with: run-sb${NC} OR ./mvnw spring-boot:run\n"
            else
                printf "${RED}❌ Failed to extract project${NC}\n"
                rm -f $name.zip
                return 1
            fi
        else
            printf "${RED}❌ Failed to create project (HTTP $http_code)${NC}\n"
            rm -f $name.zip
            return 1
        fi
    }

    # List available dependencies
    list_dependencies() {
        if ! check_requirements; then
            return 1
        fi
        
        printf "${BLUE}📦 Fetching available dependencies...${NC}\n\n"
        
        local metadata=$(fetch_metadata)
        if [[ $? -ne 0 ]]; then
            return 1
        fi
        
        # Parse dependencies with the correct structure
        local deps=$(echo "$metadata" | jq -r '
            .dependencies.values[]? | 
            "\n\u001b[1;34m" + .name + "\u001b[0m", 
            (.values[]? | "  \u001b[32m" + .id + "\u001b[0m - " + .name + 
            if .description then " \u001b[90m(" + .description + ")\u001b[0m" else "" end)
        ' 2>/dev/null)
        
        if [[ -n "$deps" ]]; then
            echo "$deps" | less -R
        else
            printf "${RED}❌ Failed to parse dependencies${NC}\n"
            printf "${YELLOW}Raw metadata saved to /tmp/spring-metadata-debug.json${NC}\n"
            echo "$metadata" > /tmp/spring-metadata-debug.json
        fi
    }

    # Show available versions
    show_versions() {
        if ! check_requirements; then
            return 1
        fi
        
        printf "${BLUE}📡 Fetching version information...${NC}\n\n"
        
        local metadata=$(fetch_metadata)
        if [[ $? -ne 0 ]]; then
            return 1
        fi
        
        printf "${BOLD}${BLUE}Spring Boot Versions:${NC}\n"
        echo "$metadata" | jq -r '.bootVersion.values[] | "  \u001b[32m" + .id + "\u001b[0m - " + .name'
        
        printf "\n${BOLD}${BLUE}Java Versions:${NC}\n"
        echo "$metadata" | jq -r '.javaVersion.values[] | "  \u001b[32m" + .id + "\u001b[0m - " + .name'
    }

    # Debug metadata fetching
    debug_metadata() {
        echo -e "${BLUE}🔍 Debug Mode - Fetching Spring Initializr Metadata${NC}\n"
        
        echo -e "${YELLOW}Testing connection to Spring Initializr...${NC}"
        local test_connection=$(curl -s -o /dev/null -w "%{http_code}" "$SPRING_API")
        echo -e "HTTP Status Code: $test_connection\n"
        
        if [[ "$test_connection" -ne 200 ]]; then
            echo -e "${RED}❌ Cannot connect to Spring Initializr${NC}"
            return 1
        fi
        
        echo -e "${YELLOW}Fetching metadata from: ${SPRING_API}/metadata/client${NC}\n"
        local metadata=$(curl -s "$SPRING_API/metadata/client")
        
        if [[ -z "$metadata" ]]; then
            echo -e "${RED}❌ No metadata received${NC}"
            return 1
        fi
        
        echo -e "${GREEN}✓ Metadata received ($(echo "$metadata" | wc -c) bytes)${NC}\n"
        
        # Validate JSON
        if echo "$metadata" | jq empty 2>/dev/null; then
            echo -e "${GREEN}✓ Valid JSON${NC}\n"
        else
            echo -e "${RED}❌ Invalid JSON${NC}"
            echo "$metadata" | head -20
            return 1
        fi
        
        # Show structure
        echo -e "${BOLD}${BLUE}Available Fields:${NC}"
        echo "$metadata" | jq -r 'keys[]' 2>/dev/null | sed 's/^/  • /'
        echo ""
        
        # Show defaults with both ID and Name
        echo -e "${BOLD}${BLUE}Default Values (ID → Name → Normalized):${NC}"
        local default_type=$(echo "$metadata" | jq -r '.type.default // "none"')
        local default_type_name=$(echo "$metadata" | jq -r --arg id "$default_type" '.type.values[] | select(.id == $id) | .name // "N/A"' 2>/dev/null)
        echo "  Type: $default_type → $default_type_name"
        
        local default_boot=$(echo "$metadata" | jq -r '.bootVersion.default // "none"')
        local default_boot_normalized=$(resolve_boot_version "$metadata" "$default_boot")
        local default_boot_name=$(echo "$metadata" | jq -r --arg id "$default_boot" '.bootVersion.values[] | select(.id == $id) | .name // "N/A"' 2>/dev/null)
        echo "  Boot Version: $default_boot → $default_boot_name → [Normalized: $default_boot_normalized]"
        
        local default_java=$(echo "$metadata" | jq -r '.javaVersion.default // "none"')
        local default_java_name=$(echo "$metadata" | jq -r --arg id "$default_java" '.javaVersion.values[] | select(.id == $id) | .name // "N/A"' 2>/dev/null)
        echo "  Java Version: $default_java → $default_java_name"
        
        local default_lang=$(echo "$metadata" | jq -r '.language.default // "none"')
        local default_lang_name=$(echo "$metadata" | jq -r --arg id "$default_lang" '.language.values[] | select(.id == $id) | .name // "N/A"' 2>/dev/null)
        echo "  Language: $default_lang → $default_lang_name"
        
        local default_pkg=$(echo "$metadata" | jq -r '.packaging.default // "none"')
        local default_pkg_name=$(echo "$metadata" | jq -r --arg id "$default_pkg" '.packaging.values[] | select(.id == $id) | .name // "N/A"' 2>/dev/null)
        echo "  Packaging: $default_pkg → $default_pkg_name"
        echo ""
        
        # Show available versions with more detail (ID and Name)
        echo -e "${BOLD}${BLUE}Project Types:${NC}"
        echo "$metadata" | jq -r '.type.values[] | "  • \(.id) → \(.name)"' 2>/dev/null
        echo ""
        
        echo -e "${BOLD}${BLUE}Available Spring Boot Versions (first 10):${NC}"
        echo "$metadata" | jq -r '.bootVersion.values[] | "  • \(.id) → \(.name)"' 2>/dev/null | head -10
        echo ""
        
        echo -e "${BOLD}${BLUE}Available Java Versions:${NC}"
        echo "$metadata" | jq -r '.javaVersion.values[] | "  • \(.id) → \(.name)"' 2>/dev/null
        echo ""
        
        # Test a sample project generation with normalized versions
        echo -e "${BOLD}${BLUE}Testing Project Generation:${NC}"
        local test_boot_raw=$(echo "$metadata" | jq -r '.bootVersion.default // empty')
        local test_boot=$(resolve_boot_version "$metadata" "$test_boot_raw")
        local test_java=$(echo "$metadata" | jq -r '.javaVersion.default // empty')
        local test_type=$(echo "$metadata" | jq -r '.type.default // empty')
        
        echo "  Using Type: $test_type"
        echo "  Boot Version: $test_boot_raw → Normalized: $test_boot"
        echo "  Java Version: $test_java"
        
        local test_url="${SPRING_API}/starter.zip?type=${test_type}&language=java&bootVersion=${test_boot}&javaVersion=${test_java}&baseDir=test&groupId=com.example&artifactId=test&name=test&packageName=com.example.test&packaging=jar&dependencies=web"
        echo -e "  Test URL: ${test_url}\n"
        
        local test_response=$(curl -s -o /dev/null -w "%{http_code}" "$test_url")
        if [[ "$test_response" -eq 200 ]]; then
            echo -e "${GREEN}✓ Project generation test successful (HTTP 200)${NC}"
            echo -e "${GREEN}  ✓ Normalized version '$test_boot' works correctly${NC}"
        else
            echo -e "${RED}❌ Project generation test failed with normalized version (HTTP $test_response)${NC}"
            echo -e "${YELLOW}Trying with original (raw) version: $test_boot_raw${NC}"
            local test_url_orig="${SPRING_API}/starter.zip?type=${test_type}&language=java&bootVersion=${test_boot_raw}&javaVersion=${test_java}&baseDir=test&groupId=com.example&artifactId=test&name=test&packageName=com.example.test&packaging=jar&dependencies=web"
            local test_response_orig=$(curl -s -o /dev/null -w "%{http_code}" "$test_url_orig")
            if [[ "$test_response_orig" -eq 200 ]]; then
                echo -e "${YELLOW}⚠️  Original version works (HTTP 200) - API requires .RELEASE suffix${NC}"
                echo -e "${YELLOW}⚠️  resolve_boot_version() may need adjustment${NC}"
            else
                echo -e "${RED}❌ Both versions failed (HTTP $test_response_orig)${NC}"
            fi
        fi
        echo ""
        
        # Test resolve_boot_version with various inputs
        echo -e "${BOLD}${BLUE}Testing resolve_boot_version() Function:${NC}"
        local test_cases=("3.5.6.RELEASE" "3.5.6" "v3.5.6" "3.5.6-RELEASE" "")
        for test_case in "${test_cases[@]}"; do
            local resolved=$(resolve_boot_version "$metadata" "$test_case")
            if [[ -z "$test_case" ]]; then
                echo "  Input: (empty) → Resolved: '$resolved'"
            else
                echo "  Input: '$test_case' → Resolved: '$resolved'"
            fi
        done
        echo ""
        
        # Save full metadata
        local output_file="/tmp/spring-initializr-metadata-$(date +%Y%m%d-%H%M%S).json"
        echo "$metadata" | jq '.' > "$output_file" 2>/dev/null
        echo -e "${GREEN}✓ Full metadata saved to: $output_file${NC}"
        echo -e "${YELLOW}Tip: Open this file to see the complete structure and available options${NC}"
    }

    # Show help
    show_help() {
        printf "${YELLOW}⚠️  This tool is in development - errors may occur with version handling${NC}\n"
        printf "${BOLD}${BLUE}Spring Initializr CLI Tool v0.0.1${NC}\n"
        echo ""
        printf "${BOLD}Usage:${NC}\n"
        echo "  spring-cli                        - Interactive mode with FZF (recommended)"
        echo "  spring-cli quick <name> [deps]    - Quick create with defaults"
        echo "  spring-cli list-deps              - List all available dependencies"
        echo "  spring-cli versions               - Show available Spring Boot & Java versions"
        echo "  spring-cli debug                  - Show raw metadata JSON"
        echo "  spring-cli help                   - Show this help"
        echo ""
        printf "${BOLD}Examples:${NC}\n"
        echo "  spring-cli"
        echo "  spring-cli quick my-api web,data-jpa,lombok"
        echo "  spring-cli list-deps"
        echo ""
        printf "${BOLD}Requirements:${NC}\n"
        echo "  • jq      - brew install jq"
        echo "  • fzf     - brew install fzf"
        echo ""
        printf "${BOLD}Environment Variables:${NC}\n"
        echo "  SPRING_CLI_DEFAULT_JAVA       - Set default Java version (default: 21)"
        echo "  SPRING_CLI_VERIFY_VERSION     - Enable API version verification (slower)"
        echo ""
        printf "${BOLD}⚠️  Known Issues:${NC}\n"
        printf "${YELLOW}  • Version suffixes (-BUILD, -RELEASE) may cause issues${NC}\n"
        printf "${YELLOW}  • If project fails to build, manually edit pom.xml/build.gradle${NC}\n"
        printf "${YELLOW}  • Remove version suffixes and the project should work${NC}\n"
        
    }

    # Main logic
    case ${1:-interactive} in
        interactive|"")
            interactive_mode
            ;;
        quick)
            quick_create "$2" "$3"
            ;;
        deps|list-deps)
            list_dependencies
            ;;
        versions|vers)
            show_versions
            ;;
        debug)
            debug_metadata
            ;;
        test-boot-version|test-version)
            test_boot_version_api "$2"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            printf "${RED}❌ Unknown command: $1${NC}\n"
            show_help
            return 1
            ;;
    esac
}

# Aliases for convenience
alias spring='spring-cli'
alias sb='spring-cli'
alias spring-new='spring-cli'