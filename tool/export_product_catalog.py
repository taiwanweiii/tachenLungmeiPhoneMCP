"""
從系統櫃網頁的產品目錄（/api/McpCatalog/products）產生 MCP 找產品用的目錄檔
CurtainMCP.Server/product-catalog.json。

為什麼需要：MCP 的 search_products 讀這個檔案（主系統沒有開放產品清單給 MCP 用），
原本檔案裡只有 A01 一筆，AI 用名稱找不到其他產品。產品有增減時重新跑一次即可，
MCP 不用重啟（檔案每次搜尋都會重讀）。

用法：
    python tool/export_product_catalog.py                      # 預設從本機開發網頁（https://localhost:30000）讀取
    python tool/export_product_catalog.py --base https://網頁位址

執行前會把現有的目錄檔備份成 product-catalog.json.bak_<時間>。
"""
import argparse
import datetime
import json
import os
import shutil
import ssl
import sys
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'CurtainMCP.Server', 'product-catalog.json')

# 名稱裡出現這些字，就補上對應的搜尋關鍵字（讓「衣櫃」「抽屜」這種籠統的詞也找得到）
KEYWORD_HINTS = ['衣櫃', '單門', '雙門', '抽屜', '吊衣', '鞋櫃', '書櫃', '電視櫃', '層板', '收納', '玻璃', '開放']


def fetch(base: str):
    url = base.rstrip('/') + '/api/McpCatalog/products'
    ctx = None
    host = urllib.parse.urlparse(url).hostname or ''
    # 本機開發網頁用自簽憑證；只對本機／區網位址略過憑證驗證
    if host in ('localhost', '127.0.0.1') or host.startswith(('10.', '192.168.')):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    with urllib.request.urlopen(url, context=ctx, timeout=60) as r:
        return json.loads(r.read().decode('utf-8'))


def to_item(p):
    no = (p.get('productNo') or '').strip()
    name = (p.get('productName') or '').strip()
    label = (p.get('label') or '').strip()
    if not no:
        return None
    kws = [k for k in KEYWORD_HINTS if k in name or k in label]
    if label and label not in kws:
        kws.append(label)
    return {
        'productNo': no,
        'name': name or label or no,
        'category': label or None,
        'keywords': kws,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--base', default='https://localhost:30000')
    args = ap.parse_args()

    products = fetch(args.base)
    items = [i for i in (to_item(p) for p in products) if i]
    if not items:
        print('目錄是空的，不覆蓋現有檔案', file=sys.stderr)
        sys.exit(1)

    out = os.path.abspath(OUT)
    if os.path.exists(out):
        stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S')
        shutil.copyfile(out, f'{out}.bak_{stamp}')
        print(f'已備份舊檔：{out}.bak_{stamp}')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(items, f, ensure_ascii=False, indent=2)
    print(f'已寫入 {len(items)} 筆：{out}')


if __name__ == '__main__':
    main()
