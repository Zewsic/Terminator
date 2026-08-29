import { Action, ActionPanel, List, closeMainWindow, showHUD, showToast, Toast } from "@raycast/api";
import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { useEffect, useState } from "react";

const execFileAsync = promisify(execFile);

type Server = {
  id: string;
  name: string;
  hostname: string;
  port: number;
  group?: string;
  tags: string[];
};

type Catalog = { version: number; servers: Server[] };

const catalogPath = join(homedir(), "Library", "Application Support", "Terminator", "Integrations", "Raycast", "servers.json");

export default function SearchServers() {
  const [servers, setServers] = useState<Server[]>();
  const [error, setError] = useState<string>();

  useEffect(() => {
    readFile(catalogPath, "utf8")
      .then((contents) => setServers((JSON.parse(contents) as Catalog).servers))
      .catch(() => setError("Open Terminator once to publish your server catalog, then try again."));
  }, []);

  if (error) return <List searchBarPlaceholder={error} />;

  return (
    <List isLoading={!servers} searchBarPlaceholder="Search saved SSH servers">
      {servers?.map((server) => {
        const address = `${server.hostname}:${server.port}`;
        return (
          <List.Item
            key={server.id}
            title={server.name}
            subtitle={address}
            keywords={[server.hostname, server.group ?? "", ...server.tags]}
            accessories={server.group ? [{ text: server.group }] : undefined}
            actions={
              <ActionPanel>
                <Action title="Connect in Terminal" onAction={() => connect(server.id, server.name)} />
                <Action.CopyToClipboard title="Copy Address" content={address} />
              </ActionPanel>
            }
          />
        );
      })}
    </List>
  );
}

async function connect(hostID: string, name: string) {
  await closeMainWindow({ clearRootSearch: true });
  const helper = await servicePath();
  if (!helper) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Terminator service not found",
      message: "Open Terminator once from /Applications, then try again.",
    });
    return;
  }
  try {
    await execFileAsync(helper, ["connect", hostID], { timeout: 120_000 });
    await showHUD(`Connecting to ${name}`);
  } catch (error) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not connect",
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

async function servicePath() {
  const candidates = [
    "/Applications/Terminator.app/Contents/Helpers/terminator-service",
    join(homedir(), "Applications/Terminator.app/Contents/Helpers/terminator-service"),
  ];
  for (const path of candidates) {
    try {
      await access(path);
      return path;
    } catch {
      continue;
    }
  }
  return undefined;
}
