from sigma.workbook import get_element
from sigma.sheetElement import FormulaSheet
from sigma.container import Container
from sigma.barChart import BarChart

# 1) Category list filter on the Overview page, targeting the shared Overview master table
mo = get_element('master-overview')
rail = get_element('syn-page-dash-1-rail')
if isinstance(mo, FormulaSheet) and isinstance(rail, Container):
    cat = mo.get_column_by_name('Category')
    ctl = sigma.control.add_list_control(rail, options=cat, target=cat)
    ctl.set_name('Category')
    ctl.set_frame(1, 14, 1, 3)

# 2) RC Revenue by Tier: bar -> pie (same element id)
tier = get_element('el-rc-revenue-by-tier')
if isinstance(tier, BarChart):
    tier.convert_to('pie')
print('done')
