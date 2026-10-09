import { describe, it, expect } from "vitest";
import demo from "../../../content/demo/story.json";
import {
  validateGraph,
  buildRelations,
  buildPhases,
  setGraphPath,
} from "./graph";
describe("canonical graph editing", () => {
  it("accepts the authoritative demo and rejects layout in game facts", () => {
    expect(validateGraph(demo)).toBe(true);
    expect(validateGraph({ ...demo, layout: {} })).toBe(false);
  });
  it("keeps private item and conditional edges distinct", () => {
    const graph = buildRelations(demo);
    expect(
      graph.edges.some(
        (e) => e.source === "action:inspect_phone" && e.label.includes("道具"),
      ),
    ).toBe(true);
    expect(
      graph.edges.some(
        (e) =>
          e.source === "clue:C2" &&
          e.target === "action:open_cabinet" &&
          e.data.kind === "condition",
      ),
    ).toBe(true);
  });
  it("edits a nested action without changing the original or unrelated facts", () => {
    const next = setGraphPath(demo, ["actions", 0, "label"], "检查录像");
    expect(next.actions[0].label).toBe("检查录像");
    expect(demo.actions[0]).not.toHaveProperty("label", "检查录像");
    expect(next.decision).toEqual(demo.decision);
    expect(validateGraph(next)).toBe(true);
  });
  it("projects fixed phases and all decision endings", () => {
    const diagram = buildPhases(demo);
    expect(
      diagram.nodes.filter((n) => n.id.startsWith("phase:")).map((n) => n.id),
    ).toEqual([
      "phase:briefing",
      "phase:exploration",
      "phase:interlude",
      "phase:decision",
    ]);
    expect(
      diagram.nodes.filter((n) => n.id.startsWith("option:")),
    ).toHaveLength(demo.decision.options.length);
  });
});
