# | 🛜 CLOUDFLARE | 🦅 IaCarus

Run from the repo root: `cd cloudflare`.

### make bucket-new

`make bucket-new` will prompt the user for a bucket name, using the prefix
defined in `iacarus/config.sh`:

```sh
# --- CLOUDFLARE R2 BUCKET CONFIG ---

CF_R2_BUCKET_BASE_NAME="cf-bucket-"
```

It also checks if the bucket already exists before creating it,
and finally lists all buckets.

```sh
iacarus/cloudflare main ❯ make bucket-new

🔍 Checking Pre-requisites...
🪣 Provisioning a new Cloudflare R2 BUCKET...
>  Type the BUCKET name to complement (cf-bucket-): bla
🔍 Checking if cf-bucket-bla exists...
🚰 Creating bucket 'cf-bucket-bla'...
✅ Bucket created successfully!

📋 Current Buckets:
-------------------
|   ListBuckets   |
+-----------------+
|  cf-bucket-bla  |
+-----------------+
```

### make bucket-list

`make bucket-list` will list all created buckets in your account.

```sh
iacarus/cloudflare main ❯ make bucket-list

🔍 Checking Pre-requisites...
🔍 Fetching buckets from R2...
-----------------------------------------------
|                 ListBuckets                 |
+---------------------------+-----------------+
|          Created          |      Name       |
+---------------------------+-----------------+
|  2025-12-03T13:55:57.276Z |  cf-bucket-bla  |
+---------------------------+-----------------+
```

### make bucket-delete

`make bucket-delete` will interactively delete objects and/or buckets from your
Cloudflare R2 account.

After listing all created buckets, you will be asked to select one to manage.

```sh
iacarus/cloudflare main ❯ make bucket-delete

🔍 Checking Pre-requisites...
🔍 Fetching buckets from R2...
Select a bucket to manage:
1) cf-bucket-bla
Enter number (or 'q' to quit): 1

You selected: 'cf-bucket-bla'
```

#### Delete specific objects (files)

You may delete objects one by one by selecting the corresponding file number.

```sh
iacarus/cloudflare main ❯ make bucket-delete
# (...)
What do you want to do?
1) Delete specific objects (files)
2) DESTROY BUCKET (Delete all files + Remove bucket)
q) Quit
Select option: 1

🔍 Listing objects in 'cf-bucket-bla'...
Select a file to DELETE:
1) file_02.txt
2) file_03.txt
3) file_04.txt
4) file_05.txt
5) file_06.txt
6) file_07.txt
7) file_08.txt
8) file_09.txt
Enter number (or 'q' to quit): 4
🔥 Deleting 'file_05.txt'...
✅ Deleted: 'file_05.txt'
Enter number (or 'q' to quit): 5
🔥 Deleting 'file_06.txt'...
✅ Deleted: 'file_06.txt'
Enter number (or 'q' to quit): q
Done. Exit.
```

#### DESTROY BUCKET (Delete all files + Remove bucket)

Alternatively, you may destroy the bucket. This action will first delete all objects,
then remove the bucket.

This action includes a "Safety Lock" that requires you to type the bucket name
to confirm.

```sh
iacarus/cloudflare main ❯ make bucket-delete
# (...)
What do you want to do?
1) Delete specific objects (files)
2) DESTROY BUCKET (Delete all files + Remove bucket)
q) Quit
Select option: 2

⚠️  WARNING: This will delete ALL data in 'cf-bucket-bla' and remove the bucket.
>  Type the bucket name 'cf-bucket-bla' to confirm: cf-bucket-bla
🔥 Emptying bucket (Recursive delete)...
delete: s3://cf-bucket-bla/file_02.txt
delete: s3://cf-bucket-bla/file_04.txt
delete: s3://cf-bucket-bla/file_03.txt
delete: s3://cf-bucket-bla/file_09.txt
delete: s3://cf-bucket-bla/file_07.txt
delete: s3://cf-bucket-bla/file_08.txt
🔥 Deleting bucket...
✅ Bucket 'cf-bucket-bla' has been obliterated.
```

### make bucket-smoke

This script runs a full cycle of standard operations on an R2 Storage Bucket.
This effectively tests and validates your account credentials.

```sh
iacarus/cloudflare main ❯ make bucket-smoke

🔍 Checking Pre-requisites...
🌫️ Starting R2 Smoke Test...
   Endpoint: https://<account-id>.r2.cloudflarestorage.com
   Bucket:   smoke-test-1764938266
   Creating bucket... OK
   Uploading object... OK
   Verifying object exists... OK
   Downloading object... OK
   Comparing content... MATCHED (Integrity Confirmed)
   Cleaning up... OK

🎉 SMOKE TEST PASSED! Your R2 keys work perfectly.
```
