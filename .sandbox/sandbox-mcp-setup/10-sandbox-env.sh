#!/bin/bash
# Show sandbox environment type so AI knows which environment it's running in

[ -n "$SANDBOX_ENV" ] && echo "Sandbox environment: $SANDBOX_ENV"
