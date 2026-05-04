import { memo, useEffect, useRef } from "react";
import type { WorldState } from "../app/types";
import type { SessionClient } from "../net/SessionClient";
import type { AssetCatalog } from "./assetCatalog";
import { WorldRenderer, type TileInteractionPayload } from "./WorldRenderer";

interface WorldCanvasProps {
  world: WorldState;
  assetCatalog: AssetCatalog | null;
  showTileDebug: boolean;
  raining: boolean;
  snowing: boolean;
  session: SessionClient;
  onTileInteraction?: (payload: TileInteractionPayload) => void;
}

export const WorldCanvas = memo(function WorldCanvas({
  world,
  assetCatalog,
  showTileDebug,
  raining,
  snowing,
  session,
  onTileInteraction
}: WorldCanvasProps) {
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
    rendererRef.current?.setTileInteractionHandler(onTileInteraction ?? null);
  }, [onTileInteraction]);

  useEffect(() => {
    rendererRef.current?.setRaining(raining);
  }, [raining]);

  useEffect(() => {
    rendererRef.current?.setSnowing(snowing);
  }, [snowing]);

  useEffect(() => {
    rendererRef.current?.render(world, assetCatalog, showTileDebug);
  }, [assetCatalog, showTileDebug, world]);

  return (
    <div
      className="world-canvas"
      data-raining={raining ? "1" : "0"}
      data-snowing={snowing ? "1" : "0"}
      data-testid="world-canvas"
      ref={rootRef}
    />
  );
});

WorldCanvas.displayName = "WorldCanvas";
