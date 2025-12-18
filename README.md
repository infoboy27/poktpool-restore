# PoktPool Restore Script

A comprehensive bash script to restore the PoktPool infrastructure from backups stored on Storj. This script automates the setup of databases, services, and applications required for the PoktPool ecosystem.

## Features

- 🔧 **Automated Setup**: Installs all required dependencies (Docker, Docker Compose, uplink CLI)
- 📦 **Database Restoration**: Downloads and restores PostgreSQL database dumps from Storj
- 🐳 **Container Management**: Builds and starts all required Docker containers
- 🔐 **Secure Configuration**: Uses `.env` file for sensitive credentials
- 🌐 **Network Management**: Automatically creates Docker networks as needed
- 🔄 **Git Integration**: Clones and updates required repositories

## Prerequisites

- Ubuntu/Debian-based Linux system
- Root or sudo access
- Internet connection
- GitHub Personal Access Token (for private repositories)
- Storj Access Grant (for downloading backups)

## Quick Start

### 1. Clone the Repository

```bash
git clone https://github.com/infoboy27/poktpool-restore.git
cd poktpool-restore
```

### 2. Configure Environment Variables

Copy the example environment file and fill in your credentials:

```bash
cp .env.example .env
```

Edit `.env` with your actual credentials:

```bash
# Git Credentials for Private Repositories
GIT_TOKEN=your_github_personal_access_token_here

# ---- STORJ ----
STORJ_BUCKET=blockchains
STORJ_PREFIX=postgres
STORJ_ACCESS_GRANT="your_storj_access_grant_here"
```

### 3. Run the Script

```bash
sudo ./restore.sh
```

The script will:
1. Install required dependencies
2. Clone required repositories
3. Download database dumps from Storj
4. Start Docker containers
5. Restore databases

## Configuration

### Environment Variables

The script uses the following environment variables (can be set in `.env` file):

#### Git Configuration
- `GIT_TOKEN`: GitHub Personal Access Token for accessing private repositories
  - Generate at: https://github.com/settings/tokens
  - Required scopes: `repo` (for private repositories)

#### Storj Configuration
- `STORJ_BUCKET`: Storj bucket name (default: `blockchains`)
- `STORJ_PREFIX`: Path prefix within the bucket (default: `postgres`)
- `STORJ_ACCESS_GRANT`: Storj Access Grant for uplink CLI
  - Get from Storj web console or run `uplink setup`

#### Optional Configuration
- `BASE_DIR`: Base directory for operations (default: `/root`)
- `WORKDIR`: Working directory for cloned repos (default: `$BASE_DIR/poktpool`)
- `GIT_BRANCH`: Git branch to checkout (default: `main`)

### Example `.env` File

```bash
# Git Credentials
GIT_TOKEN=ghp_your_token_here

# Storj Configuration
STORJ_BUCKET=blockchains
STORJ_PREFIX=postgres
STORJ_ACCESS_GRANT="your_access_grant_here"

# Optional Overrides
# BASE_DIR=/root
# WORKDIR=/root/poktpool
# GIT_BRANCH=main
```

## What Gets Installed

### System Dependencies
- Git
- curl
- jq
- unzip
- ca-certificates
- Docker Engine
- Docker Compose v2
- Storj uplink CLI

### Repositories Cloned
- `blockjobpicker` - Block job picker service
- `poktpooldb` - Database setup and configuration
- `poktpoolui` - User interface
- `poktpool` - Main PoktPool application

### Docker Containers Started
- **poktpooldb**: PostgreSQL database for PoktPool
- **nodedb**: PostgreSQL database for node data (waxtrax)
- **blockjobpicker**: Block job picker service
- **poktpool**: Main PoktPool API service
- **poktpoolui**: PoktPool UI (if available)

## Database Restoration

The script downloads and restores the following database dumps:

1. **poktpooldb**: Main PoktPool database
   - Remote: `sj://${STORJ_BUCKET}/${STORJ_PREFIX}/poktpooldb/20251217_142112_poktpooldb.dump`
   - Local: `20251217_142112_poktpooldb.dump`

2. **waxtrax**: Node database
   - Remote: `sj://${STORJ_BUCKET}/${STORJ_PREFIX}/waxtrax/20251217_142112_waxtrax.dump`
   - Local: `20251217_142112_waxtrax.dump`

## Docker Network

The script automatically creates a Docker network named `poktpool` that is shared between all services. This allows containers to communicate with each other using service names.

## Troubleshooting

### Git Clone Fails

**Error**: `fatal: could not read Username for 'https://github.com'`

**Solution**: 
- Ensure `GIT_TOKEN` is set in `.env` file
- Verify the token has `repo` scope
- Check that repositories are accessible with the token

### Storj Access Fails

**Error**: `uplink does NOT have configured access`

**Solution**:
- Verify `STORJ_ACCESS_GRANT` is set correctly in `.env`
- Check that the access grant is valid and not expired
- Ensure the bucket and prefix paths are correct

### Database Creation Fails

**Error**: `Could not create DB 'poktpooldb'`

**Solution**:
- Check that PostgreSQL containers are running: `docker ps`
- Verify database user has proper permissions
- Check container logs: `docker logs poktpooldb-db`

### Network Not Found

**Error**: `network poktpool declared as external, but could not be found`

**Solution**: The script automatically creates this network. If you see this error, ensure you're running the latest version of the script.

### Container Not Starting

**Solution**:
- Check Docker logs: `docker logs <container-name>`
- Verify docker-compose files are present
- Check disk space: `df -h`
- Verify ports are not already in use

## Manual Steps (if needed)

### Check Container Status

```bash
docker ps
cd /root/poktpool/poktpooldb && docker compose ps
```

### View Logs

```bash
docker logs -f blockjobpicker
docker logs -f poktpooldb-db
docker logs -f nodedb-db
```

### Restart Services

```bash
cd /root/poktpool/poktpooldb && docker compose restart
cd /root/poktpool/poktpool && docker compose restart
```

### Access Databases

```bash
# PoktPool DB
docker exec -it poktpooldb-db psql -U postgres_chadmin -d poktpooldb

# Node DB (waxtrax)
docker exec -it nodedb-db psql -U vultradmin -d waxtrax
```

## Script Output

The script provides colored output:
- 🟢 **Green**: Success messages and information
- 🟡 **Yellow**: Warnings (non-critical issues)
- 🔴 **Red**: Errors (script will exit)

## Security Notes

- ⚠️ **Never commit `.env` file** - It contains sensitive credentials
- 🔐 Keep your GitHub token and Storj access grant secure
- 🚫 The `.env` file is in `.gitignore` to prevent accidental commits
- 🔒 Use strong passwords for database users in production

## Support

For issues or questions:
1. Check the troubleshooting section above
2. Review container logs for detailed error messages
3. Ensure all prerequisites are met
4. Verify credentials are correct

## License

This script is provided as-is for PoktPool infrastructure restoration.

## Changelog

### Latest Updates
- Changed working directory from `poktpool-restore` to `poktpool`
- Fixed database creation to handle existing databases
- Added automatic Docker network creation
- Improved error handling and user feedback
- Added support for Storj configuration via `.env` file
