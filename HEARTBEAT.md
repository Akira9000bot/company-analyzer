# HEARTBEAT.md - Continuous Improvement Protocol

## On Every Heartbeat Wake

When this file is read during heartbeat, execute the following parallel improvement tasks:

### Task 1: Review Recent Mistakes
- Read memory/YYYY-MM-DD.md for today and past 3 days
- Identify mistakes, errors, or suboptimal outcomes
- Log patterns that need fixing

### Task 2: Cost Analysis & Optimization  
- Review /tmp/company-analyzer-costs.log
- Check if analysis costs exceed estimates
- Identify optimization opportunities

### Task 3: Code/Skill Improvements
- Check skills/company-analyzer/ for:
  - Bug reports or issues in scripts
  - Outdated documentation
  - Missing error handling
- Propose fixes

### Task 4: Memory Maintenance
- Consolidate duplicate memories
- Archive old daily files to MEMORY.md
- Remove obsolete information

## Execution Protocol

1. Spawn 4 sub-agents in parallel (one per task)
2. Each agent has 60 second timeout
3. Collect results
4. If improvements identified, implement top priority fixes
5. Document changes in memory/YYYY-MM-DD.md

## Success Criteria

- At least one improvement implemented per heartbeat
- Costs tracked and trending down
- No repeated mistakes
- Skills continuously refined

---
*This file triggers active improvement mode on each heartbeat*
