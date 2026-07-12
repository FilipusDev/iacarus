#!/bin/bash

set -e

source config.sh

echo -e "\n${C_INFO}🦅 IaCarus Setup Wizard${C_RESET}"
echo "----------------------------------------"

# 1. Dependency Check
echo -e "${C_INFO}🔍 Checking dependencies...${C_RESET}"
DEPS=("hcloud" "aws" "make" "nc")
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

# 2. Environment Setup
echo -e "\n${C_INFO}📝 Configuration Setup...${C_RESET}"
if [ ! -f .env ]; then
  if [ -f .env.example ]; then
    cp example.env .env
    echo -e "${C_SUCCESS}✅ Created .env from template.${C_RESET}"
    echo -e "${C_WARN}⚠️  ACTION REQUIRED: Edit .env and fill in your secrets!${C_RESET}"
  else
    echo -e "${C_ERROR}❌ example.env not found!${C_RESET}"
  fi
else
  echo -e "${C_SUCCESS}✅ .env already exists.${C_RESET}"
fi

# 3. Directory Structure
echo -e "\n${C_INFO}📂 Verifying project structure...${C_RESET}"
chmod +x *.sh hetzner/*.sh cloudflare/*.sh 2>/dev/null || true
echo -e "${C_SUCCESS}✅ Made scripts executable.${C_RESET}"

# 4. Instructions
echo -e "\n${C_INFO}🚀 Ready to fly!${C_RESET}"
echo "----------------------------------------"
echo "1. Edit .env with your secrets."
echo "2. Go to 'hetzner/' to create servers:  cd hetzner && make new"
echo "3. Go to 'cloudflare/' to manage R2:    cd cloudflare && make new"
echo "HINT: Check Cloudflare's R2 Toke API Client IP Address Filtering at: R2 Account Details"
echo "----------------------------------------"
