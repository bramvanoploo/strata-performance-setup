#!/usr/bin/env bash
# PLUGIN_ID: example-pack
# PLUGIN_NAME: example-pack
# PLUGIN_DESC: Example performance tweak pack

# Register each tweak in this pack using register_tweak:
#   --id                   Unique snake_case step ID
#   --stars                1..5 relative performance/utility rating
#   --tier                 recommended | opt_in | experimental | high_idle
#   --os                   linux | macos | both
#   --laptop-recommended   true | false
#   --vm-supported         true | false
register_tweak \
  --id "example_tweak" \
  --stars 3 \
  --tier "recommended" \
  --os "linux" \
  --laptop-recommended true \
  --vm-supported true

# Return 0 if this tweak is applicable to the current machine, 1 otherwise.
applicable_example_tweak() {
  [[ "$IS_MACOS" == false ]]
}

# Print a short title for the Optimization Index table.
title_example_tweak() {
  echo "Example Host Optimization"
}

# Return 0 if the tweak is currently applied on the system, 1 otherwise.
status_example_tweak() {
  [[ -f /etc/example-tweak.conf ]]
}

# Print a clear explanation of what this tweak does and why.
explain_example_tweak() {
  echo "Explains what example_tweak changes and how it helps LLM inference."
}

# Apply the optimization using core helpers (run_root, write_sysctl_with_prev, add_kernel_param, install_service, ...).
apply_example_tweak() {
  echo -e "${C_CYAN}Applying example_tweak...${C_RESET}"
}

# Cleanly revert the optimization.
revert_example_tweak() {
  echo -e "${C_CYAN}Reverting example_tweak...${C_RESET}"
}
