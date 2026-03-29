import { useEffect, useRef } from "react";
import type { ClientState } from "../app/types";
import type { AssetCatalog } from "./assetCatalog";
import { WorldRenderer } from "./WorldRenderer";

interface WorldCanvasProps {
  state: ClientState;
  assetCatalog: AssetCatalog | null;
  showTileDebug: boolean;
}

export function WorldCanvas({ state, assetCatalog, showTileDebug }: WorldCanvasProps) {
  const rootRef = useRef<HTMLDivElement | null>(null);
  const rendererRef = useRef<WorldRenderer | null>(null);

  useEffect(() => {
    if (!rootRef.current) {
      return;
    }

    const renderer = new WorldRenderer();
    renderer.mount(rootRef.current);
    renderer.render(state, assetCatalog, showTileDebug);
    rendererRef.current = renderer;

    return () => {
      renderer.destroy();
      rendererRef.current = null;
    };
  }, []);

  useEffect(() => {
    rendererRef.current?.render(state, assetCatalog, showTileDebug);
  }, [assetCatalog, showTileDebug, state]);

  return <div className="world-canvas" ref={rootRef} />;
}
