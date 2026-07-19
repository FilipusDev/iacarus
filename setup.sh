#!/bin/bash

set -e

echo -e "\n🦅 IaCarus Setup Wizard"
echo "----------------------------------------"

# 1. Environment Setup
# Must run before sourcing config.sh: config.sh requires .env to already
# exist and exits otherwise, so on a fresh clone it would abort here first.
echo -e "\n📝 Configuration Setup..."
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp .env.example .env
    echo "✅ Created .env from template."
    echo "⚠️  ACTION REQUIRED: Edit .env and fill in your secrets!"
  else
    echo "❌ .env.example not found!"
    exit 1
  fi
else
  echo "✅ .env already exists."
fi

source config.sh

# 2. Dependency Check
echo -e "\n${C_INFO}🔍 Checking dependencies...${C_RESET}"
DEPS=("hcloud" "aws" "make" "nc" "curl" "jq" "glances")
MISSING=0

for cmd in "${DEPS[@]}"; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "   ${C_ERROR}❌ Missing: $cmd${C_RESET}"
    MISSING=1
  else
    echo -e "   ${C_SUCCESS}✅ Found: $cmd${C_RESET}"
  fi
done

if [ $MISSING -eq 1 ]; then
  echo -e "\n${C_WARN}⚠️  Please install missing dependencies (pacman -S, apt install, ...)${C_RESET}"
fi

# 3. Directory Structure
echo -e "\n${C_INFO}📂 Verifying project structure...${C_RESET}"
chmod +x *.sh hetzner/*.sh cloudflare/*.sh mon/*.sh 2>/dev/null || true
echo -e "${C_SUCCESS}✅ Made scripts executable.${C_RESET}"

# 4. Instructions
echo -e "\n${C_INFO}🚀 Ready to fly!${C_RESET}"
echo "----------------------------------------"
echo "1. Edit .env with your secrets."
echo "2. Go to 'hetzner/' to create servers:  cd hetzner && make vps-new"
echo "3. Go to 'cloudflare/' to manage R2:    cd cloudflare && make bucket-new"
echo "HINT: Check Cloudflare's R2 Toke API Client IP Address Filtering at: R2 Account Details"
echo "----------------------------------------"
