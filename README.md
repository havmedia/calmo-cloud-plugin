# calmo.cloud plugin for Claude Code

Connects [Claude Code](https://code.claude.com) to [calmo.cloud](https://calmo.cloud), the hosting platform for Odoo, and teaches it how to work with it.

The plugin brings:

- **The calmo.cloud MCP server**, already configured. Claude Code asks for your API token once and keeps it in your system's credential store.
- **Skills**:
  - `migrate-odoo`: moves an existing Odoo onto calmo.cloud, from Docker, a package or source install, Odoo.sh, Odoo Online or another hoster. It inventories the old system, plans the move with you, prepares everything without downtime, and switches over only when you say so. See [AI-assisted migration](https://calmo.cloud/docs/migration/ai-assisted-migration).

## Install

In Claude Code:

```
/plugin marketplace add havmedia/calmo-cloud-plugin
/plugin install calmo@calmo-cloud
```

Claude Code then asks for your **calmo.cloud API token**. Owners and admins create one under **Developer → API Tokens** in the calmo.cloud panel. Create a token just for this assistant, so you can revoke it on its own. Run `/mcp` to check that **calmo** is connected.

Your team's plan must include the API (every plan from Starter up).

## Use

Ask in plain words, for example:

```
Move the Odoo on root@erp.example.com to calmo.cloud. Inventory the server first,
then show me the plan and ask me before anything goes offline.
```

The migration skill needs root SSH from your machine to the old server where there is one. For Odoo.sh and Odoo Online it works from a downloaded backup.

## Update

```
/plugin marketplace update calmo-cloud
```

## Security

The token gives the assistant access to your whole calmo.cloud team; root SSH gives it the old server. Run it on a machine you trust, read what it proposes before you approve, and revoke the token under **Developer → API Tokens** when you no longer need it. Destructive actions on calmo.cloud need the exact name of their target, and the assistant is told to ask you first.

## License

MIT
