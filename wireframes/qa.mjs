import {pathToFileURL, fileURLToPath} from 'node:url';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';

const modulePath=process.argv[2];
const {chromium}=await import(modulePath?pathToFileURL(path.resolve(modulePath)).href:'playwright');
const here=path.dirname(fileURLToPath(import.meta.url));
const output=path.join(here,'qa');
await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.CHESS_QA_CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
const page=await browser.newPage({viewport:{width:1440,height:1120},deviceScaleFactor:1});
const errors=[];
page.on('pageerror',error=>errors.push(error.message));
const report={screens:0,states:0,routes:0,overflows:[],errors,checks:[]};
try{
  await page.goto(pathToFileURL(path.join(here,'index.html')).href);
  const inventory=await page.evaluate(()=>WIREFRAMES.screens.map(s=>({id:s.id,states:s.states})));
  assert.equal(inventory.length,28);
  report.screens=inventory.length;
  for(const screen of inventory){
    for(const state of screen.states){
      await page.evaluate(({id,state})=>WIREFRAMES.navigate(id,state),{id:screen.id,state});
      await page.waitForFunction(({id,state})=>document.querySelector('.notes h3')?.textContent===`${id} / ${state.replaceAll('-',' ')}`,{id:screen.id,state});
      const result=await page.evaluate(()=>{
        const phone=document.querySelector('.phone');
        const content=phone.querySelector('.phone-content');
        const links=[...phone.querySelectorAll('[data-go]')].map(el=>({id:el.dataset.go,state:el.dataset.state||'default'}));
        const invalid=links.filter(l=>!WIREFRAMES.screens.some(s=>s.id===l.id&&s.states.includes(l.state)));
        return {count:links.length,invalid,overflow:content.scrollWidth>content.clientWidth+1,text:content.textContent.trim().length};
      });
      assert.equal(result.invalid.length,0,`${screen.id}/${state}: invalid routes ${JSON.stringify(result.invalid)}`);
      assert.ok(result.text>20,`${screen.id}/${state}: empty content`);
      if(result.overflow)report.overflows.push(`${screen.id}/${state}/desktop`);
      report.states++;report.routes+=result.count;
    }
  }
  report.checks.push('Every screen/state renders nonempty content and all declared destinations exist');
  await page.locator('#screen-search').fill('queue');
  assert.equal(await page.locator('.nav-link:visible').count(),1);
  await page.locator('#screen-search').fill('');
  report.checks.push('Screen search filters the inventory');
  await page.evaluate(()=>WIREFRAMES.navigate('W01'));
  await page.getByRole('button',{name:'Add a player',exact:true}).click();
  await page.getByRole('button',{name:'Find player',exact:true}).click();
  await page.waitForURL(url=>url.hash==='#W02/invalid');
  await page.locator('[data-username]').fill('swiftrook');
  await page.getByRole('button',{name:'Find player',exact:true}).click();
  await page.getByRole('button',{name:'Track this player',exact:true}).click();
  await page.waitForURL(url=>url.hash==='#W03/default');
  report.checks.push('Onboarding validation, profile confirmation and import navigation');
  await page.evaluate(()=>WIREFRAMES.navigate('W09'));
  await page.waitForURL(url=>url.hash==='#W09/default');
  await page.screenshot({path:path.join(output,'review-desktop.png'),fullPage:true});
  await page.getByRole('button',{name:'Inspect better continuation',exact:true}).click();
  await page.getByRole('button',{name:'Next →',exact:true}).click();
  await page.waitForURL(url=>url.hash==='#W10/reply');
  report.checks.push('Review to hypothetical continuation and next legal position');
  await page.evaluate(()=>WIREFRAMES.navigate('W05'));
  await page.waitForURL(url=>url.hash==='#W05/default');
  await page.screenshot({path:path.join(output,'analytics-desktop.png'),fullPage:true});
  await page.setViewportSize({width:390,height:1100});
  for(const screen of inventory){
    for(const state of screen.states){
      await page.evaluate(({id,state})=>WIREFRAMES.navigate(id,state),{id:screen.id,state});
      await page.waitForFunction(({id,state})=>document.querySelector('.notes h3')?.textContent===`${id} / ${state.replaceAll('-',' ')}`,{id:screen.id,state});
      const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1||document.querySelector('.phone-content').scrollWidth>document.querySelector('.phone-content').clientWidth+1);
      if(overflow)report.overflows.push(`${screen.id}/${state}/mobile`);
    }
  }
  await page.evaluate(()=>WIREFRAMES.navigate('W15','heat'));
  await page.waitForURL(url=>url.hash==='#W15/heat');
  await page.screenshot({path:path.join(output,'queue-mobile.png'),fullPage:true});
  report.checks.push('All screen/state layouts checked for horizontal overflow at 390px');
  await page.setViewportSize({width:320,height:1100});
  for(const screen of inventory){
    await page.evaluate(id=>WIREFRAMES.navigate(id),screen.id);
    await page.waitForFunction(id=>document.querySelector('.notes h3')?.textContent===`${id} / default`,screen.id);
    const overflow=await page.evaluate(()=>document.documentElement.scrollWidth>innerWidth+1||document.querySelector('.phone-content').scrollWidth>document.querySelector('.phone-content').clientWidth+1);
    if(overflow)report.overflows.push(`${screen.id}/default/320px`);
  }
  report.checks.push('All default layouts checked at 320px');
  await page.setViewportSize({width:1640,height:1100});
  await page.getByRole('button',{name:'View all screens',exact:true}).click();
  assert.equal(await page.locator('.gallery .phone').count(),28);
  await page.screenshot({path:path.join(output,'screen-atlas.png'),fullPage:true});
  report.checks.push('Gallery contains all 28 screens');
  assert.deepEqual(report.overflows,[],'Horizontal overflow found');
  assert.deepEqual(errors,[],'Browser script errors');
  report.passed=true;
}finally{
  await writeFile(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report,null,2));
  await browser.close();
}
