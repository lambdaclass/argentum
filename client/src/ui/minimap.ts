import type { WorldState } from "../app/types";

export function drawMinimap(canvas: HTMLCanvasElement, world: WorldState, size: number) {
  canvas.width = size;
  canvas.height = size;

  const context = canvas.getContext("2d");
  if (!context) {
    return;
  }

  context.fillStyle = "#09111a";
  context.fillRect(0, 0, size, size);

  const map = world.map;
  if (!map) {
    context.strokeStyle = "rgba(255, 220, 146, 0.22)";
    context.strokeRect(0.5, 0.5, size - 1, size - 1);
    return;
  }

  const scaleX = size / map.width;
  const scaleY = size / map.height;

  for (let y = 1; y <= map.height; y += 1) {
    for (let x = 1; x <= map.width; x += 1) {
      const tile = map.tiles[(y - 1) * map.width + (x - 1)] ?? 0;
      context.fillStyle = tile === 0 ? "#26422f" : "#13222a";
      context.fillRect((x - 1) * scaleX, (y - 1) * scaleY, Math.ceil(scaleX), Math.ceil(scaleY));
    }
  }

  context.fillStyle = "#d2a04e";
  for (const exit of map.exits) {
    context.fillRect((exit.x - 1) * scaleX, (exit.y - 1) * scaleY, Math.max(2, scaleX), Math.max(2, scaleY));
  }

  context.fillStyle = "#8fb9df";
  for (const other of Object.values(world.others)) {
    context.beginPath();
    context.arc((other.x - 0.5) * scaleX, (other.y - 0.5) * scaleY, Math.max(2, size / 60), 0, Math.PI * 2);
    context.fill();
  }

  context.fillStyle = "#e6df9a";
  for (const npc of map.npcs) {
    context.beginPath();
    context.arc((npc.x - 0.5) * scaleX, (npc.y - 0.5) * scaleY, Math.max(1.5, size / 80), 0, Math.PI * 2);
    context.fill();
  }

  if (world.self.x != null && world.self.y != null) {
    context.fillStyle = "#ff6a54";
    context.beginPath();
    context.arc(
      (world.self.x - 0.5) * scaleX,
      (world.self.y - 0.5) * scaleY,
      Math.max(3, size / 40),
      0,
      Math.PI * 2
    );
    context.fill();
  }

  context.strokeStyle = "rgba(255, 220, 146, 0.28)";
  context.strokeRect(0.5, 0.5, size - 1, size - 1);
}
