#!/usr/bin/env bash

# --- Configuration ---
# Set the directory where your projects are stored.
# If PROJECTS_DIR environment variable is set, use it; otherwise, default to ~/Projects
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/Projects}"
# Set the maximum depth for scanning project directories
PROJECT_SCAN_DEPTH=3 # Adjust as needed (e.g., 2 for ~/Projects/Type/ProjectName)

# --- Safety Checks ---
if ! command -v tmux &> /dev/null; then
    echo "Error: tmux is not installed." >&2
    exit 1
fi

if ! command -v fzf &> /dev/null; then
    echo "Error: fzf is not installed." >&2
    exit 1
fi

if [[ ! -d "$PROJECTS_DIR" ]]; then
    echo "Error: Projects directory '$PROJECTS_DIR' not found." >&2
    echo "Set the PROJECTS_DIR environment variable or change the script default." >&2
    exit 1
fi

# --- Helper Functions ---

# Function to sanitize session names (tmux doesn't like '.' or ':')
sanitize_session_name() {
    echo "$1" | sed 's/[.:]/_/g'
}

# --- Main Logic ---

# 1. Get active tmux sessions
#    Format: "session_name [Active]"
active_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sed 's/$/ \[Active]/')

# 2. Find potential project sessions (Git repositories)
#    Find git dirs, get parent dir path, then format as "basename --- /full/path [Project]"
#    Using find ... -print0 | xargs -0 is safer for names with spaces/special chars
found_projects=$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth "$PROJECT_SCAN_DEPTH" -type d -name .git -print0 2>/dev/null | \
    xargs -0 -I {} dirname "{}" | \
    while IFS= read -r path; do
        basename=$(basename "$path")
        # Skip if basename is empty or just '.'
        [[ -z "$basename" || "$basename" == "." ]] && continue
        sanitized_name=$(sanitize_session_name "$basename")
        echo "$sanitized_name --- $path [Project]" # Store name and path, separated
    done
)

# 3. Combine active sessions and project paths
#    Use awk to extract just the session/project name for comparison and uniqueness
combined_list=$( (echo "$active_sessions"; echo "$found_projects") | \
    awk -F ' --- ' '{print $1}' | \
    sort -u)

# If no sessions or projects found, exit
if [[ -z "$combined_list" ]]; then
  echo "No active sessions or projects found in '$PROJECTS_DIR'."
  exit 0
fi


# 4. Use fzf to select a session/project
#    Use --query="$1" to pre-fill fzf if an argument is passed to the script
#    Use awk magic to re-format the combined list for fzf display
#    FZF displays "Name [Type]" but returns the original full line ("Name [Active]" or "Name --- Path [Project]")
selected_output=$( (echo "$active_sessions"; echo "$found_projects") | \
    awk -F ' --- ' '{
        if (NF==1) { # Active session line ("Name [Active]")
            print $0 # Keep as is
        } else { # Project line ("Name --- Path [Project]")
            print $1 $NF " --- " $2 # Format for display: "Name[Project] --- Path" -> Returns "Name --- Path [Project]"
        }
    }' | \
    sort | \
    fzf --reverse --prompt="Select Tmux Session/Project > " \
        --preview '
            LINE=$(echo {} | sed "s/ \[.*\]//"); # Remove type tag for processing
            if echo "$LINE" | grep -q " --- "; then # Project
                PROJECT_PATH=$(echo "$LINE" | awk -F " --- " "{print \$2}");
                echo "Project Path: $PROJECT_PATH";
                echo "---";
                (ls -lah "$PROJECT_PATH" | head -n 10); # Show directory listing preview
                echo "---";
                (git -C "$PROJECT_PATH" log --oneline --graph --decorate --all -n 10 2>/dev/null) # Show git log preview
            else # Active Session
                SESSION_NAME=$(echo "$LINE" | awk "{print \$1}");
                echo "Active Session: $SESSION_NAME";
                echo "---";
                tmux list-windows -t "$SESSION_NAME" -F "#{window_index}: #{window_name} #{?window_active,(active),}" ; # Show windows
                echo "---";
                tmux capture-pane -pt "$SESSION_NAME":. -S -10 # Show some pane content
            fi' \
        --bind 'ctrl-d:preview-down,ctrl-u:preview-up' \
        --query="$1" --select-1 --exit-0 )


# Exit if fzf was cancelled (e.g., Esc)
if [[ -z "$selected_output" ]]; then
    exit 0
fi

# 5. Process the selection

is_project=0
selected_name=""
project_path=""

# Check if the selection contains the '---' separator, indicating a project path
if echo "$selected_output" | grep -q " --- "; then
    is_project=1
    selected_name=$(echo "$selected_output" | awk -F ' --- ' '{print $1}')
    project_path=$(echo "$selected_output" | awk -F ' --- ' '{print $2}' | sed 's/ \[Project\]$//') # Extract path and remove tag
else
    # It's an active session, extract the name (remove '[Active]')
    selected_name=$(echo "$selected_output" | sed 's/ \[Active\]$//')
fi

# Check if the selected session already exists
session_exists=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Fx "$selected_name")

if [[ -n "$session_exists" ]]; then
    # Session exists - Attach or Switch
    if [[ -z "$TMUX" ]]; then
        # Not inside tmux - attach
        echo "Attaching to existing session: $selected_name"
        tmux attach-session -t "$selected_name"
    else
        # Inside tmux - switch client
        echo "Switching to existing session: $selected_name"
        tmux switch-client -t "$selected_name"
    fi
else
    # Session does not exist - Must be a project selection to create a new one
    if [[ "$is_project" -eq 1 ]] && [[ -n "$project_path" ]] && [[ -d "$project_path" ]]; then
        echo "Creating and attaching to new session: $selected_name"

        # Create detached session, cd to project dir, name first window 'nvim'
        tmux new-session -ds "$selected_name" -c "$project_path" -n nvim
        # Send nvim command to the first window (index 0, named nvim)
        tmux send-keys -t "$selected_name:nvim" "nvim" C-m

        # Create and name the second window 'lazygit'
        tmux new-window -t "$selected_name": -c "$project_path" -n lazygit
        # Send lazygit command to the second window
        tmux send-keys -t "$selected_name:lazygit" "lazygit" C-m

        # Create and name the third window 'shell1'
        tmux new-window -t "$selected_name": -c "$project_path" -n shell1
        # (It starts with an empty shell)

        # Create and name the fourth window 'shell2'
        tmux new-window -t "$selected_name": -c "$project_path" -n shell2
        # (It starts with an empty shell)

        # Select the first window (nvim) to be active when attaching
        tmux select-window -t "$selected_name:nvim"

        # Attach or Switch to the newly created session
        if [[ -z "$TMUX" ]]; then
            tmux attach-session -t "$selected_name"
        else
            tmux switch-client -t "$selected_name"
        fi
    else
        echo "Error: Selected project path '$project_path' for '$selected_name' is invalid or not found." >&2
        exit 1
    fi
fi

exit 0
