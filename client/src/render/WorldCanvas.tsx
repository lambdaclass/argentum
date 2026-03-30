import { useEffect, useRef } from "react";
import type { WorldState } from "../app/types";
import type { SessionClient } from "../net/SessionClient";
import type { AssetCatalog } from "./assetCatalog";
import { WorldRenderer } from "./WorldRenderer";

interface WorldCanvasProps {
  world: WorldState;
  assetCatalog: AssetCatalog | null;
  showTileDebug: boolean;
  session: SessionClient;
}

export function WorldCanvas({ world, assetCatalog, showTileDebug, session }: WorldCanvasProps) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const rendererRef = useRef<WorldRenderer | null>(null);

  useEffect(() => {
    if (!rootRef.current) {
      return;
    }

    const renderer = new WorldRenderer();
    renderer.mount(rootRef.current);
    renderer.setRuntimeTick((now) => {
      session.tick(now);
    });
    renderer.render(world, assetCatalog, showTileDebug);
    rendererRef.current = renderer;
    session.setRenderer(renderer);

    return () => {
      session.setRenderer(null);
      renderer.setRuntimeTick(null);
      renderer.destroy();
      rendererRef.current = null;
    };
  }, [session]);

  useEffect(() => {
    rendererRef.current?.render(world, assetCatalog, showTileDebug);
  }, [assetCatalog, showTileDebug, world]);

  return <div className="world-canvas" ref={rootRef} />;
}
