#!/usr/bin/env python3
"""Real Chromium regression. Requires Python Playwright and Chromium; no network."""
import argparse
import base64
import json
import pathlib
import select
import subprocess
import tempfile
from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', default='target/debug/simplemarkdown-daemon')
    parser.add_argument('--chromium', default='/usr/bin/chromium')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temp:
        root = pathlib.Path(temp)
        (root / 'README.md').write_text('placeholder')
        (root / '.env').write_text('SECRET_NOT_FOR_PREVIEW')
        (root / 'config.json').write_text('{"secret":"SECRET_NOT_FOR_PREVIEW"}')
        (root / 'active.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>')
        (root / 'pixel.png').write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aC1cAAAAASUVORK5CYII='))
        proc = subprocess.Popen([args.binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def send(value):
            proc.stdin.write(json.dumps(value) + '\n')
            proc.stdin.flush()
        def response():
            assert select.select([proc.stdout], [], [], 10)[0], 'daemon response timed out'
            return json.loads(proc.stdout.readline())
        hostile = [
            '# Preview', '',
            '<script>window.pwned=true;fetch("/.env").then(r=>r.text()).then(x=>window.leak=x)</script>', '',
            '<img src=x onerror="window.pwned=true">', '',
            '<svg onload="window.pwned=true"></svg>', '',
            '<iframe srcdoc="<script>parent.pwned=true</script>"></iframe>', '',
            '[bad](data:text/html,hello)', '', '![safe](pixel.png)', '',
            'Inline <b onclick="window.pwned=true">text</b>',
        ]
        try:
            send({'type':'serve','id':1,'session':'security','path':str(root/'README.md'),'lines':hostile,'port':0})
            reply=response()
            assert reply['type']=='serve_result', reply
            url=reply['url']
            with sync_playwright() as p:
                browser=p.chromium.launch(executable_path=args.chromium, headless=True, args=['--no-sandbox'])
                page=browser.new_page()
                dialogs=[]
                page.on('dialog',lambda d:(dialogs.append(d.message),d.dismiss()))
                page.goto(url)
                page.wait_for_function('window.SM && document.querySelector("#sm-theme").title.startsWith("Theme:")')
                assert page.locator('#sm-doc script, #sm-doc iframe, #sm-doc svg, #sm-doc [onerror], #sm-doc [onclick]').count()==0
                assert page.evaluate('window.pwned === undefined && window.leak === undefined')
                assert page.locator('#sm-doc a').get_attribute('href')=='#'
                page.wait_for_function('document.querySelector("#sm-doc img").naturalWidth === 1')
                before=page.locator('html').get_attribute('data-theme')
                page.locator('#sm-theme').click()
                assert page.locator('html').get_attribute('data-theme')!=before
                for path in ['.env','config.json','active.svg']:
                    r=page.request.get(url.rstrip('/')+'/'+path)
                    assert r.status==404,(path,r.status)
                    assert 'SECRET_NOT_FOR_PREVIEW' not in r.text()
                # Defense in depth: even an accidentally inserted handler/script is refused.
                page.evaluate('''() => {let s=document.createElement('script');s.textContent='window.injected=true';document.body.append(s);let img=document.createElement('img');img.setAttribute('onerror','window.injected=true');img.src='/absent';document.body.append(img)}''')
                page.wait_for_timeout(200)
                assert page.evaluate('window.injected === undefined')
                # SSE is still functional and uses exactly the same escaping policy.
                send({'type':'serve_update','session':'security','lines':['# Updated','','<img src=x onerror="window.pwned=true">']})
                page.wait_for_function('document.querySelector("#sm-doc").textContent.includes("Updated")')
                assert page.locator('#sm-doc [onerror]').count()==0
                assert page.evaluate('window.pwned === undefined')
                assert not dialogs,dialogs
                browser.close()
            print('browser preview security: PASS (Chromium, real daemon, initial + SSE + CSP + assets)')
        finally:
            proc.terminate()
            proc.communicate(timeout=10)

if __name__=='__main__': main()
