何时读我：需要查看完整阶段编排、checkpoint 路由或 DOT 流程图时。

## 完整流程

> 下图是完整阶段编排（两档同序）。**档位 B（交互）**：explore/analyze/plan/finish/evolve 由控制器在会话内执行、TodoWrite 记录阶段状态、checkpoint 以"自查前置不变量"替代；**loop 阶段两档都调 `run-track-a.sh` 托管 qodercli**（控制器不内联写码）。

```dot
digraph autopilot {
    rankdir=TB;
    "User requirement received" [shape=doublecircle];
    "Determine task type" [shape=diamond];
    "Initialize autopilot/changes/<name>/" [shape=box];
    "Needs init?" [shape=diamond];
    "Invoke Skill(autopilot-init)" [shape=box];
    "Invoke Skill(autopilot-checkpoint) for init" [shape=box];
    "Invoke Skill(autopilot-explore)" [shape=box];
    "Invoke Skill(autopilot-checkpoint) for explore" [shape=box];
    "Invoke Skill(autopilot-analyze)" [shape=box];
    "Invoke Skill(autopilot-checkpoint) for analyze" [shape=box];
    "Invoke Skill(autopilot-plan)" [shape=box];
    "Invoke Skill(autopilot-checkpoint) for plan" [shape=box];
    "Invoke Skill(autopilot-loop)" [shape=box];
    "Invoke Skill(autopilot-checkpoint) for loop" [shape=box];
    "Invoke Skill(autopilot-finish)" [shape=box];
    "Invoke Skill(autopilot-checkpoint) for finish" [shape=box];
    "Invoke Skill(autopilot-evolve)" [shape=box];
    "Invoke Skill(autopilot-checkpoint) for evolve" [shape=box];
    "Done" [shape=doublecircle];

    "User requirement received" -> "Determine task type";
    "Determine task type" -> "Initialize autopilot/changes/<name>/";
    "Initialize autopilot/changes/<name>/" -> "Needs init?";
    "Needs init?" -> "Invoke Skill(autopilot-init)" [label="no AGENTS.md or incomplete harness"];
    "Needs init?" -> "Invoke Skill(autopilot-explore)" [label="harness ready, feature/bugfix"];
    "Needs init?" -> "Invoke Skill(autopilot-plan)" [label="harness ready, spec-ready"];
    "Invoke Skill(autopilot-init)" -> "Invoke Skill(autopilot-checkpoint) for init";
    "Invoke Skill(autopilot-checkpoint) for init" -> "Invoke Skill(autopilot-explore)" [label="feature/bugfix"];
    "Invoke Skill(autopilot-checkpoint) for init" -> "Invoke Skill(autopilot-plan)" [label="spec-ready"];
    "Invoke Skill(autopilot-explore)" -> "Invoke Skill(autopilot-checkpoint) for explore";
    "Invoke Skill(autopilot-checkpoint) for explore" -> "Invoke Skill(autopilot-analyze)" [label="feature/bugfix"];
    "Invoke Skill(autopilot-analyze)" -> "Invoke Skill(autopilot-checkpoint) for analyze";
    "Invoke Skill(autopilot-checkpoint) for analyze" -> "Invoke Skill(autopilot-plan)";
    "Invoke Skill(autopilot-plan)" -> "Invoke Skill(autopilot-checkpoint) for plan";
    "Invoke Skill(autopilot-checkpoint) for plan" -> "Invoke Skill(autopilot-loop)";
    "Invoke Skill(autopilot-loop)" -> "Invoke Skill(autopilot-checkpoint) for loop";
    "Invoke Skill(autopilot-checkpoint) for loop" -> "Invoke Skill(autopilot-finish)";
    "Invoke Skill(autopilot-finish)" -> "Invoke Skill(autopilot-checkpoint) for finish";
    "Invoke Skill(autopilot-checkpoint) for finish" -> "Invoke Skill(autopilot-evolve)";
    "Invoke Skill(autopilot-evolve)" -> "Invoke Skill(autopilot-checkpoint) for evolve";
    "Invoke Skill(autopilot-checkpoint) for evolve" -> "Done";
}
```
