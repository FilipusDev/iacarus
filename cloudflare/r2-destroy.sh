#!/bin/bash

set -e

source ../config.sh
source ../utils.sh

# 1. Check configuration variables availability
echo -e "\n${C_INFO}🔍 Checking Pre-requisites...${C_RESET}"
if [[ -z "$AWS_ACCESS_KEY_ID" || -z "$AWS_SECRET_ACCESS_KEY" || -z "$AWS_DEFAULT_REGION" || -z "$CF_R2_S3_CLIENT_URL" ]]; then
    echo -e "${C_ERROR}❌ Error: Missing configuration variables.${C_RESET}"
    exit 1
fi

echo -e "${C_INFO}🔍 Fetching buckets from R2...${C_RESET}"

# 2. Get Bucket List
mapfile -t BUCKETS < <(aws s3api list-buckets --endpoint-url "$CF_R2_S3_CLIENT_URL" --query "Buckets[].Name" --output text | tr '\t' '\n')

if [ ${#BUCKETS[@]} -eq 0 ]; then
    echo -e "${C_WARN}🤷 No buckets found.${C_RESET}"
    exit 0
fi

echo "Select a bucket to manage:"
PS3="Enter number (or 'q' to quit): "

select SELECTED_BUCKET in "${BUCKETS[@]}"; do
    if [[ "$REPLY" == "q" ]]; then echo "Exit."; exit 0; fi
    
    if [ -n "$SELECTED_BUCKET" ]; then
        echo -e "\n${C_INFO}You selected: ${C_HIGH}'$SELECTED_BUCKET'${C_RESET}"
        break
    else
        echo "Invalid selection."
    fi
done

# 3. Choose Operation Mode
echo -e "\nWhat do you want to do?"
echo "1) Delete specific objects (files)"
echo "2) DESTROY BUCKET (Delete all files + Remove bucket)"
echo "q) Quit"

read -p "Select option: " ACTION

case $ACTION in
    1)
        # --- MODE A: DELETE OBJECTS ---
        echo -e "\n${C_INFO}🔍 Listing objects in '$SELECTED_BUCKET'...${C_RESET}"
        
        # Fetch object keys
        mapfile -t OBJECTS < <(aws s3api list-objects-v2 --bucket "$SELECTED_BUCKET" --endpoint-url "$CF_R2_S3_CLIENT_URL" --query "Contents[].Key" --output text | tr '\t' '\n')

        # Handle Empty Bucket
        if [[ ${#OBJECTS[@]} -eq 0 ]] || [[ ${#OBJECTS[@]} -eq 1 && "$OBJECTS" == "None" ]]; then
            echo -e "${C_WARN}🤷 This bucket is already empty.${C_RESET}"
            exit 0
        fi

        echo -e "Select a file to ${C_ERROR}DELETE${C_RESET}:"
        select FILE_KEY in "${OBJECTS[@]}"; do
            if [[ "$REPLY" == "q" ]]; then echo "Done. Exit."; exit 0; fi
            
            if [ -n "$FILE_KEY" ]; then
                echo -e "${C_WARN}🔥 Deleting '$FILE_KEY'...${C_RESET}"
                aws s3api delete-object --bucket "$SELECTED_BUCKET" --key "$FILE_KEY" --endpoint-url "$CF_R2_S3_CLIENT_URL"
                echo -e "${C_SUCCESS}✅ Deleted: '$FILE_KEY'${C_RESET}"
                # We exit after one deletion to keep logic simple, or you could 'continue' loop
                continue
            else
                echo "Invalid selection."
            fi
        done
        ;;

    2)
        # --- MODE B: NUKE BUCKET ---
        echo -e "\n${C_ERROR}⚠️  WARNING: This will delete ALL data in '$SELECTED_BUCKET' and remove the bucket.${C_RESET}"
        echo -n ">  Type the bucket name '$SELECTED_BUCKET' to confirm: "
        read CONFIRMATION

        if [ "$CONFIRMATION" == "$SELECTED_BUCKET" ]; then
            echo -e "${C_WARN}🔥 Emptying bucket (Recursive delete)...${C_RESET}"
            # Use high-level 's3 rm --recursive' for speed
            aws s3 rm "s3://$SELECTED_BUCKET" --recursive --endpoint-url "$CF_R2_S3_CLIENT_URL"

            echo -e "${C_ERROR}🔥 Deleting bucket...${C_RESET}"
            aws s3api delete-bucket --bucket "$SELECTED_BUCKET" --endpoint-url "$CF_R2_S3_CLIENT_URL"

            echo -e "${C_SUCCESS}✅ Bucket '$SELECTED_BUCKET' has been obliterated.${C_RESET}"
        else
            echo -e "${C_ERROR}❌ Name did not match. Aborted.${C_RESET}"
        fi
        ;;

    q)
        echo "Exit."
        exit 0
        ;;
    *)
        echo "Invalid option. Aborted"
        exit 1
        ;;
esac
