// document.querySelectorAll('.nav>li>a').forEach(item => {
//   item.addEventListener('click', (event) => {
//     let elementA = event.target;
//     let subNav = elementA.parentNode.querySelector('.nav');
//     let subNavStyleDisplay = subNav.style.display
//     subNav.style.display = subNavStyleDisplay === 'flex' ? 'none' : 'flex';
//   })

//   subNav = item.parentNode.querySelector('.nav')
//   if (subNav) {
//     let elementSpanIcon = subNav.previousElementSibling;
//     if (elementSpanIcon) {
//       elementSpanIcon.style.display = 'inline-block';
//     }
//   }
// })

document.querySelectorAll('.nav>li>.nav').forEach(item => {
  let elementIcon = item.parentNode.querySelector('span.iconfont');
  elementIcon.style.display = 'inline';
})