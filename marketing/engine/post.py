#!/usr/bin/env python3
"""Publish a rendered video to TikTok + Instagram Reels + YouTube Shorts through Upload-Post.

Dry run by default (prints what would be sent). Real upload needs --confirm.
  export UPLOAD_POST_API_KEY=...   (upload-post.com -> API Keys)
  export UPLOAD_POST_USER=flexoleague   (profile name you created in Upload-Post)
  python3 post.py ../scripts/v01_ranked_gym.json --when 2026-11-14T17:00:00 --tz America/New_York --confirm
Docs: https://docs.upload-post.com/api/upload-video
"""
import argparse, json, os, sys, uuid, urllib.request, mimetypes
p = argparse.ArgumentParser()
p.add_argument('spec'); p.add_argument('--when', help='local datetime, e.g. 2026-11-14T17:00:00 (omit = post now)')
p.add_argument('--tz', default='America/New_York')
p.add_argument('--platforms', default='tiktok,instagram,youtube')
p.add_argument('--private', action='store_true', help='test mode: TikTok SELF_ONLY, YouTube private')
p.add_argument('--confirm', action='store_true', help='actually send (otherwise dry run)')
a = p.parse_args()
spec = json.load(open(a.spec)); vid = spec['id']; post = spec['post']
video = os.environ.get('VIDEO') or os.path.join(os.path.dirname(os.path.abspath(a.spec)), '..', 'videos', vid + '.mp4')
if not os.path.exists(video): sys.exit(f'no video {video}: render it first or set VIDEO=path')
tags = ' '.join('#' + t for t in post.get('hashtags', []))
caption = f"{post['caption']}\n\n{tags}"
yt_title = (post['title'] + ' #shorts')[:100]
fields = [('user', os.environ.get('UPLOAD_POST_USER', '<UPLOAD_POST_USER>')),
          ('title', caption), ('youtube_title', yt_title), ('description', caption),
          ('privacy_level', 'SELF_ONLY' if a.private else 'PUBLIC_TO_EVERYONE'),
          ('is_aigc', 'false'), ('media_type', 'REELS'), ('share_to_feed', 'true'),
          ('privacyStatus', 'private' if a.private else 'public'), ('categoryId', '17'),
          ('tags', ','.join(post.get('hashtags', [])))]
for pl in a.platforms.split(','): fields.append(('platform[]', pl.strip()))
if a.when: fields += [('scheduled_date', a.when), ('timezone', a.tz)]
print(json.dumps({'video': video, 'fields': fields}, indent=1, ensure_ascii=False))
if not a.confirm: print('\nDRY RUN: nothing sent. Add --confirm to publish.'); sys.exit(0)
key = os.environ.get('UPLOAD_POST_API_KEY') or sys.exit('set UPLOAD_POST_API_KEY')
b = uuid.uuid4().hex; body = b''
for k, v in fields: body += f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode()
body += f'--{b}\r\nContent-Disposition: form-data; name="video"; filename="{vid}.mp4"\r\nContent-Type: video/mp4\r\n\r\n'.encode() + open(video, 'rb').read() + f'\r\n--{b}--\r\n'.encode()
req = urllib.request.Request('https://api.upload-post.com/api/upload', data=body, method='POST', headers={
    'Authorization': f'Apikey {key}', 'Content-Type': f'multipart/form-data; boundary={b}', 'Idempotency-Key': vid + (a.when or '')})
try:
    with urllib.request.urlopen(req, timeout=300) as r: print(r.status, r.read().decode()[:2000])
except urllib.error.HTTPError as e: print('HTTP', e.code, e.read().decode()[:2000]); sys.exit(1)
