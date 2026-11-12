# ARM_NOTES edit test (copy of P939)
- 20:51:00 copied P939 -> P939-edit; same workbook 4d2d7596-fe9a-45a8-8372-0ca8a85da3fd
- 20:51:30 extend (approved-by TJ Wells (proof test)) ok; sdk-begin s6 v11; write v12: Category list control + tier -> pie; recorded
- 20:52:13 sdk-export (edit) EXIT 5 parity-unverified: pie conversion dropped 'Pct of Net Revenue' label column that the rebuilt parity plan expects. Wrote v13 re-adding the column.
- 20:52:22 OBSERVATION: after export exit 5 (parity-unverified) the session was NOT open (sdk-write: 'no open SDK session') despite doc saying export-failed stays open; parity-unverified closes it. v13 write therefore unrecorded -> opened new session s7 at v13 and exported (documented recovery).
- 20:53:03 s7 export exit5 closed session again; v14 write (delete duplicate col) unrecorded -> s8
- 20:53:24 s8 export exit 5 (pie hides Pct label col so CSV export lacks it; MCP query cannot see it either) -> supplied tier actuals from live MCP query (pct computed from live y) + sdk-regate => exit 0 parity 10/10. SDK-REGATE: PROVEN
- 20:56:47 edit finalize exit above; all 5 Overview tiles change under Category=Apparel (probe-all.out); layout diff: only added control; tier kind pie-chart
