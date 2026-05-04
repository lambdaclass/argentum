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

function isSelfPositionOnlyChange(previous: WorldState, next: WorldState) {
  if (
    previous.mapId !== next.mapId ||
    previous.mapStatus !== next.mapStatus ||
    previous.mapError !== next.mapError ||
    previous.map !== next.map ||
    previous.groundObjects !== next.groundObjects ||
    previous.chatBubbles !== next.chatBubbles ||
    previous.targetTile !== next.targetTile ||
    previous.combatTexts !== next.combatTexts ||
    previous.fxEvents !== next.fxEvents ||
    previous.walkIntervalMs !== next.walkIntervalMs ||
    previous.others !== next.others
  ) {
    return false;
  }

  const { x: previousX, y: previousY, ...previousSelf } = previous.self;
  const { x: nextX, y: nextY, ...nextSelf } = next.self;

  if (previousX === nextX && previousY === nextY) {
    return false;
  }

  return Object.entries(previousSelf).every(
    ([key, value]) => nextSelf[key as keyof typeof nextSelf] === value
  );
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
  const renderedWorldRef = useRef<WorldState | null>(null);

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
    renderedWorldRef.current = world;
    rendererRef.current = renderer;
    session.setRenderer(renderer);

    return () => {
      session.setRenderer(null);
      renderer.setRuntimeTick(null);
      renderer.destroy();
      rendererRef.current = null;
      renderedWorldRef.current = null;
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
    const renderedWorld = renderedWorldRef.current;
    if (renderedWorld && isSelfPositionOnlyChange(renderedWorld, world)) {
      renderedWorldRef.current = world;
      return;
    }

    rendererRef.current?.render(world, assetCatalog, showTileDebug);
    renderedWorldRef.current = world;
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
