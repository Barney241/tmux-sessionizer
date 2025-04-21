#!/usr/bin/env bash

# --- Configuration ---
PROJECTS_DIR="${PROJECTS_DIR:-$HOME/Projects}"
PROJECT_SCAN_DEPTH=3

# --- Safety Checks ---
if ! command -v tmux &> /dev/null; then echo "Error: tmux not installed." >&2; exit 1; fi
if ! command -v fzf &> /dev/null; then echo "Error: fzf not installed." >&2; exit 1; fi
if ! command -v awk &> /dev/null; then echo "Error: awk not installed." >&2; exit 1; fi
if [[ ! -d "$PROJECTS_DIR" ]]; then echo "Error: Projects directory '$PROJECTS_DIR' not found." >&2; exit 1; fi

# --- Helper Functions ---
sanitize_session_name() {
    echo "$1" | sed 's/[.:]/_/g'
}
DELIMITER="|"

# --- Main Logic ---

# 1. Get active tmux sessions
active_sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | sed "s/$/$DELIMITER\[Active]$DELIMITER/")

# 2. Find potential project sessions (Git repositories)
found_projects=$(find "$PROJECTS_DIR" -mindepth 1 -maxdepth "$PROJECT_SCAN_DEPTH" -type d -name .git -print0 2>/dev/null | \
    xargs -0 -I {} dirname "{}" | \
    while IFS= read -r path; do
        basename=$(basename "$path")
        [[ -z "$basename" || "$basename" == "." ]] && continue
        sanitized_name=$(sanitize_session_name "$basename")
        # Store sanitized name, tag, separator, and path
        echo "$sanitized_name$DELIMITER$DELIMITER$path"
    done
)

# 3. Combine active sessions and project paths for fzf input
#    Format: "DisplayName---[Active]---DataPart"
#    - Sessions: "SessionName---[Active]---" (DataPart is empty)
#    - Projects: "ProjectName------ /path/to/project" active part is empty
combined_list_for_fzf=$(
    echo "$active_sessions"
    echo "$found_projects"
)

# If no sessions or projects found, exit
if [[ -z "$combined_list_for_fzf" ]]; then
  echo "No active sessions or projects found in '$PROJECTS_DIR'."
  exit 0
fi

# Simpler Awk approach for prioritization:
combined_list_for_fzf=$(echo "$combined_list_for_fzf" | \
    awk -F "$DELIMITER" '
    BEGIN { OFS=FS } # Keep the output field separator the same as input
    {
        name = $1
        is_active = ($2 == "[Active]")

        # If we see an active session, store it and mark it as preferred
        if (is_active) {
            lines[name] = $0
            preferred[name] = 1
        }
        # If we see a non-active session, only store it if no preferred (active) version exists for this name
        else if (!(name in preferred)) {
            lines[name] = $0
        }
    }
    END {
        # Print the stored lines (active ones took precedence)
        for (name in lines) {
            print lines[name]
        }
    }
')


# If deduplication resulted in an empty list (unlikely but possible)
if [[ -z "$combined_list_for_fzf" ]]; then
  echo "No unique sessions or projects found after deduplication."
  exit 0
fi

combined_list_for_fzf=$(echo "$combined_list_for_fzf" | sort --field-separator "$DELIMITER" -k2,2r -k1,1)

#echo "$combined_list_for_fzf" # Debugging output removed/commented

#4. Use fzf to select
selected_output=$( echo "$combined_list_for_fzf" | \
    fzf --prompt="Select Tmux Session/Project > " \
        --delimiter "$DELIMITER" --with-nth '{1} {2}' \
        --tiebreak=index \
        --preview '
            # Use full paths to commands provided by Nix dependencies
            _tmux=$(command -v tmux)
            _ls=$(command -v ls)
            _head=$(command -v head)
            _git=$(command -v git)

            name={1}
            type={2}
            path={3}

            if [[ "$type" == "[Active]" ]]; then
                echo "Active Session: $name";
                echo "--- Windows ---"
                $_tmux list-windows -t "$name" -F "#{window_index}: #{window_name} #{?window_active,(active),}" ;
                echo "--- Last Pane Content (Bottom 10 lines) ---"
                $_tmux capture-pane -pt "$name":. -S -10
            elif [[ -n "$path" ]]; then
                echo "Project: $name";
                echo "Path: $path";
                echo "--- Contents (Top 10) ---"
                ($_ls -lah "$path" 2>/dev/null | $_head -n 10);
                echo "--- Git Log (Last 10) ---"
                ($_git -C "$path" log --oneline --graph --decorate --all -n 10 2>/dev/null || echo "Not a git repo or no history.")
            else
                # {..} is the fzf placeholder for the original full line
                echo "Unknown type: {..}"
            fi

        ' \
        --query "$1" --select-1 --exit-0 )


# Exit if fzf was cancelled
if [[ -z "$selected_output" ]]; then
    exit 0
fi


# 5. Process the selection
#    Selected_output contains the full line "DisplayPart --- DataPart"
is_project=0
selected_name=""
project_path=""
display_part=$(echo "$selected_output" | awk -F "$DELIMITER" '{print $1}')
data_part=$(echo "$selected_output" | awk -F "$DELIMITER" '{print $3}')

if [[ -n "$data_part" ]]; then # Project - data_part contains the path
    is_project=1
    project_path="$data_part"
    selected_name="$display_part" # Use display part directly as sanitized name
else # Session - data_part is empty
    is_project=0
    selected_name="$display_part" # Use display part directly as session name
fi

# Ensure selected_name is not empty (basic sanity check)
if [[ -z "$selected_name" ]]; then
    echo "Error: Could not determine session/project name from selection." >&2
    exit 1
fi

# Check if the session already exists (using the extracted name)
session_exists=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep -Fx "$selected_name")

if [[ -n "$session_exists" ]]; then
    # Session exists - Attach or Switch
    if [[ -z "$TMUX" ]]; then
        echo "Attaching to existing session: $selected_name"
        tmux attach-session -t "$selected_name"
    else
        echo "Switching to existing session: $selected_name"
        tmux switch-client -t "$selected_name"
    fi
else
    # Session does not exist - Must be a project selection to create a new one
    if [[ "$is_project" -eq 1 ]] && [[ -n "$project_path" ]] && [[ -d "$project_path" ]]; then
        echo "Creating and attaching to new session: $selected_name based on project $project_path"
        # Need full path for nvim and lazygit if they are expected to be specific versions or installed via Nix
        # Assuming standard names for now
        _nvim=$(command -v nvim || echo nvim)
        _lazygit=$(command -v lazygit || echo lazygit)

        tmux new-session -ds "$selected_name" -c "$project_path" -n nvim
        tmux send-keys -t "$selected_name:nvim" "$_nvim" C-m
        tmux new-window -t "$selected_name": -c "$project_path" -n lazygit
        tmux send-keys -t "$selected_name:lazygit" "$_lazygit" C-m
        tmux new-window -t "$selected_name": -c "$project_path" -n shell1
        tmux new-window -t "$selected_name": -c "$project_path" -n shell2
        tmux select-window -t "$selected_name:nvim"

        if [[ -z "$TMUX" ]]; then
            tmux attach-session -t "$selected_name"
        else
            tmux switch-client -t "$selected_name"
        fi
    elif [[ "$is_project" -eq 1 ]]; then
         # Project was selected, but path is invalid (should be caught earlier, but belt-and-suspenders)
        echo "Error: Selected project path '$project_path' for '$selected_name' is invalid or not found." >&2
        exit 1
    else
        # This case means an active session was selected but doesn't actually exist?
        # Should theoretically not happen if list-sessions was accurate.
        echo "Error: Selected session '$selected_name' not found, and it wasn't identified as a project." >&2
        exit 1
    fi
fi

exit 0
