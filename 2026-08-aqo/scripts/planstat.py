#!/usr/bin/env python3
"""Извлекает из JSON-плана EXPLAIN (ANALYZE, FORMAT JSON) метрики качества оценок.

Считает главное, ради чего затевается всё исследование: во сколько раз
планировщик ошибся в числе строк — в корне плана и в худшем из узлов.

Использование: planstat.py <plan.json>
Печатает одну строку CSV без заголовка:
    root_est,root_act,root_err,max_err,max_err_node,exec_ms,plan_ms,shape
"""
import json
import sys


def err(est, act):
    """Во сколько раз оценка расходится с фактом, в любую сторону."""
    est = max(est, 1.0)
    act = max(act, 1.0)
    return max(est / act, act / est)


def walk(node, out):
    loops = node.get("Actual Loops", 1) or 1
    est = float(node.get("Plan Rows", 0))
    # Actual Rows в EXPLAIN — это среднее за один проход цикла, а Plan Rows
    # тоже на один проход. Сравниваем их напрямую, без домножения на loops.
    act = float(node.get("Actual Rows", 0))
    name = node.get("Node Type", "?")
    rel = node.get("Relation Name") or node.get("Alias")
    if rel:
        name = f"{name}({rel})"
    out.append((name, est, act, loops))
    for child in node.get("Plans", []):
        walk(child, out)


def main():
    with open(sys.argv[1]) as f:
        data = json.load(f)
    plan = data[0]["Plan"]
    nodes = []
    walk(plan, nodes)

    root_name, root_est, root_act, _ = nodes[0]
    worst = max(nodes, key=lambda n: err(n[1], n[2]))

    # Форма плана: типы узлов сверху вниз, без имён отношений. По ней видно,
    # сменился ли план, даже когда время выполнения почти не изменилось.
    shape = ">".join(n[0].split("(")[0] for n in nodes)

    print(
        "%.0f,%.0f,%.1f,%.1f,%s,%.1f,%.1f,%s"
        % (
            root_est,
            root_act,
            err(root_est, root_act),
            err(worst[1], worst[2]),
            worst[0],
            data[0].get("Execution Time", 0),
            data[0].get("Planning Time", 0),
            shape,
        )
    )


if __name__ == "__main__":
    main()
